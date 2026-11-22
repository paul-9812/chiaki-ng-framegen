// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Robz Play frame generation - Apple's own frame interpolation on macOS 26+.
// Uses VideoToolbox's low-latency frame interpolation, which runs on the GPU / Neural
// Engine of Apple silicon and is meant for live content such as games and calls.
//
// Based on apple_interpolator.mm from Robz Play (kutsalkiremitci/robz-play, pull request 2
// by recepkizil). Changed here: pictures larger than one Apple session accepts are split
// into overlapping horizontal bands, each interpolated by its own session and stitched back
// with a feathered seam. macOS 26.2 refuses more than 921600 pixels per session (1280x720),
// so without this a 1080p stream gets no generated frames there.

#include "robzfg/apple_interpolator.h"

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <VideoToolbox/VTFrameProcessor.h>
#import <VideoToolbox/VTFrameProcessor_LowLatencyFrameInterpolation.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <mutex>
#include <vector>

namespace robzfg
{

namespace
{
// What one Apple session accepts on macOS 26.2 ("must not exceed 921600").
const int DEFAULT_BAND_PIXELS = 921600;
// Neighbouring bands share at least this many rows, so that things moving up or down
// across a seam are seen whole by both sides.
const int MIN_BAND_OVERLAP = 96;
// Rows over which one band fades into the next, in the middle of the shared rows.
const int SEAM_FEATHER = 64;

void setError(std::string *error, const std::string &text)
{
	if(error)
		*error = text;
}

// Copies `rows` luma rows of an NV12 picture, starting at row `top`, into a pixel buffer.
void copyIn(const Nv12View &src, int top, int rows, CVPixelBufferRef dst)
{
	CVPixelBufferLockBaseAddress(dst, 0);
	uint8_t *y = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(dst, 0);
	uint8_t *uv = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(dst, 1);
	const size_t ys = CVPixelBufferGetBytesPerRowOfPlane(dst, 0);
	const size_t uvs = CVPixelBufferGetBytesPerRowOfPlane(dst, 1);
	for(int row = 0; row < rows; row++)
		memcpy(y + row * ys, src.y + (size_t)(top + row) * src.y_stride, src.width);
	for(int row = 0; row < rows / 2; row++)
		memcpy(uv + row * uvs, src.uv + (size_t)(top / 2 + row) * src.uv_stride, src.width);
	CVPixelBufferUnlockBaseAddress(dst, 0);
}

void tagColor(CVPixelBufferRef pb, const ColorInfo &color)
{
	const bool bt601 = color.matrix == ColorMatrix::BT601;
	CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey,
		bt601 ? kCVImageBufferYCbCrMatrix_ITU_R_601_4 : kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
	CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey,
		bt601 ? kCVImageBufferColorPrimaries_SMPTE_C : kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
	CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
		kCVAttachmentMode_ShouldPropagate);
}

// A locked, read-only view of one plane of a pixel buffer.
struct PlaneReader
{
	const uint8_t *base = nullptr;
	size_t stride = 0;
};
} // namespace

struct AppleInterpolator::Impl
{
	// One Apple session and the pictures it works on: the whole picture, or one band of it.
	struct Band
	{
		int top = 0; // first luma row of the band inside the whole picture
		VTFrameProcessor *processor = nil;
		CVPixelBufferRef prev = nullptr;
		CVPixelBufferRef cur = nullptr;
		// generated frames of the current pair, one per phase
		std::vector<CVPixelBufferRef> made;
	};

	int frames_between = 1;
	int band_pixel_limit = 0; // 0: whole picture if the system takes it, bands otherwise
	// set when a whole-picture session turned out not to work after all: use bands from now on
	bool whole_picture_failed = false;
	int w = 0;
	int h = 0;
	int band_height = 0;
	std::vector<Band> bands;
	// for every luma row of the whole picture: the band it comes from, and how much of the
	// next band is mixed in (0..256; 0 = none)
	std::vector<uint8_t> row_band;
	std::vector<uint16_t> row_next_weight;
	VTLowLatencyFrameInterpolationConfiguration *configuration = nil;
	CVPixelBufferPoolRef source_pool = nullptr;
	CVPixelBufferPoolRef destination_pool = nullptr;
	int64_t counter = 0;
	ColorInfo color;
	bool color_set = false;
	std::vector<float> phases;
	bool made_valid = false;

	void dropMade()
	{
		for(Band &band : bands)
		{
			for(CVPixelBufferRef pb : band.made)
				CVPixelBufferRelease(pb);
			band.made.clear();
		}
		made_valid = false;
	}
	void releaseFrames()
	{
		for(Band &band : bands)
		{
			if(band.prev)
				CVPixelBufferRelease(band.prev);
			if(band.cur)
				CVPixelBufferRelease(band.cur);
			band.prev = band.cur = nullptr;
		}
		dropMade();
	}
	void closeSession()
	{
		releaseFrames();
		for(Band &band : bands)
		{
			if(band.processor)
				[band.processor endSession];
			band.processor = nil;
		}
		bands.clear();
		row_band.clear();
		row_next_weight.clear();
		configuration = nil;
		if(source_pool)
			CVPixelBufferPoolRelease(source_pool);
		if(destination_pool)
			CVPixelBufferPoolRelease(destination_pool);
		source_pool = destination_pool = nullptr;
		w = h = band_height = 0;
	}

	static CVPixelBufferPoolRef makePool(NSDictionary *attributes, int w, int h)
	{
		NSMutableDictionary *a = [attributes mutableCopy];
		a[(id)kCVPixelBufferWidthKey] = @(w);
		a[(id)kCVPixelBufferHeightKey] = @(h);
		a[(id)kCVPixelBufferPixelFormatTypeKey] = @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
		if(!a[(id)kCVPixelBufferIOSurfacePropertiesKey])
			a[(id)kCVPixelBufferIOSurfacePropertiesKey] = @{};
		CVPixelBufferPoolRef pool = nullptr;
		CVPixelBufferPoolCreate(nullptr, nullptr, (__bridge CFDictionaryRef)a, &pool);
		return pool;
	}

	// The first rows of the bands needed to cover `height` rows with bands `rows` high.
	// Empty when the picture cannot be covered sensibly.
	static std::vector<int> planBands(int height, int rows)
	{
		std::vector<int> tops;
		if(rows >= height)
		{
			tops.push_back(0);
			return tops;
		}
		if(rows < 2 * MIN_BAND_OVERLAP)
			return tops;
		const int count = (height - MIN_BAND_OVERLAP + (rows - MIN_BAND_OVERLAP) - 1) / (rows - MIN_BAND_OVERLAP);
		for(int i = 0; i < count; i++)
		{
			// spread evenly; even rows only, so that the chroma rows line up
			int top = (int)std::lround((double)i * (height - rows) / (count - 1));
			top &= ~1;
			tops.push_back(top);
		}
		tops.back() = height - rows;
		return tops;
	}

	// Starts one session per band. Any way of failing counts: on macOS 26.2 a picture that is
	// too large makes startSession return YES and still report the reason in the error.
	bool startBands(int width, int rows, const std::vector<int> &tops, std::string *error)
	{
		@autoreleasepool
		{
			configuration = [[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:width
				frameHeight:rows numberOfInterpolatedFrames:frames_between];
			if(!configuration)
			{
				setError(error, "Apple frame interpolation does not accept this picture size");
				return false;
			}
			for(int top : tops)
			{
				Band band;
				band.top = top;
				band.processor = [[VTFrameProcessor alloc] init];
				NSError *ns_error = nil;
				const BOOL started = [band.processor startSessionWithConfiguration:configuration error:&ns_error];
				if(!started || ns_error)
				{
					setError(error, std::string("Apple frame interpolation could not start: ")
						+ (ns_error ? ns_error.localizedDescription.UTF8String : "unknown error"));
					if(started)
						[band.processor endSession];
					for(Band &open : bands)
						[open.processor endSession];
					bands.clear();
					configuration = nil;
					return false;
				}
				bands.push_back(band);
			}
			source_pool = makePool(configuration.sourcePixelBufferAttributes, width, rows);
			destination_pool = makePool(configuration.destinationPixelBufferAttributes, width, rows);
		}
		if(!source_pool || !destination_pool)
		{
			setError(error, "could not allocate picture buffers");
			return false;
		}
		return true;
	}

	void planSeams()
	{
		row_band.assign((size_t)h, 0);
		row_next_weight.assign((size_t)h, 0);
		for(int row = 0; row < h; row++)
		{
			int owner = 0;
			int weight = 0;
			for(size_t k = 0; k + 1 < bands.size(); k++)
			{
				const int shared_begin = bands[k + 1].top;
				const int shared_end = bands[k].top + band_height;
				const int feather = std::max(2, std::min(SEAM_FEATHER, shared_end - shared_begin) & ~1);
				const int fade_begin = ((shared_begin + shared_end) / 2 - feather / 2) & ~1;
				if(row < fade_begin)
					break;
				if(row < fade_begin + feather)
				{
					owner = (int)k;
					// the two luma rows of one chroma row share a weight, so both planes fade alike
					weight = (((row & ~1) - fade_begin + 1) * 256) / feather;
					break;
				}
				owner = (int)k + 1;
			}
			row_band[(size_t)row] = (uint8_t)owner;
			row_next_weight[(size_t)row] = (uint16_t)weight;
		}
	}

	bool openSession(int width, int height, std::string *error)
	{
		closeSession();
		std::string whole_error;
		const bool try_whole = band_pixel_limit <= 0 && !whole_picture_failed;
		if(try_whole && startBands(width, height, {0}, &whole_error))
		{
			band_height = height;
		}
		else
		{
			closeSession();
			const int limit = band_pixel_limit > 0 ? band_pixel_limit : DEFAULT_BAND_PIXELS;
			// rows per band: as many as the limit allows, a multiple of 16
			int rows = std::min(height, (limit / width) & ~15);
			if((int64_t)width * height <= limit)
				rows = height;
			const std::vector<int> tops = planBands(height, rows);
			if(tops.empty())
			{
				setError(error, try_whole && !whole_error.empty() ? whole_error
					: "Apple frame interpolation does not accept this picture size");
				return false;
			}
			std::string band_error;
			if(!startBands(width, rows, tops, &band_error))
			{
				closeSession();
				setError(error, try_whole && !whole_error.empty() ? whole_error + "; in bands: " + band_error : band_error);
				return false;
			}
			band_height = rows;
		}
		w = width;
		h = height;
		planSeams();
		phases.clear();
		for(int k = 1; k <= frames_between; k++)
			phases.push_back((float)k / (float)(frames_between + 1));
		return true;
	}

	// Generates the in-between frames of one band. Runs on any thread; touches only `band`.
	bool makeBand(Band &band, std::string *error)
	{
		@autoreleasepool
		{
			// Apple's processor wants increasing timestamps; the real frames sit one unit apart
			const int32_t scale = 1000;
			VTFrameProcessorFrame *previous = [[VTFrameProcessorFrame alloc] initWithBuffer:band.prev
				presentationTimeStamp:CMTimeMake((counter - 1) * scale, scale)];
			VTFrameProcessorFrame *source = [[VTFrameProcessorFrame alloc] initWithBuffer:band.cur
				presentationTimeStamp:CMTimeMake(counter * scale, scale)];
			if(!previous || !source)
			{
				setError(error, "could not wrap the source pictures");
				return false;
			}
			NSMutableArray<VTFrameProcessorFrame *> *destinations = [NSMutableArray array];
			NSMutableArray<NSNumber *> *phase_list = [NSMutableArray array];
			for(float p : phases)
			{
				CVPixelBufferRef out = nullptr;
				if(CVPixelBufferPoolCreatePixelBuffer(nullptr, destination_pool, &out) != kCVReturnSuccess || !out)
				{
					setError(error, "could not allocate an output picture");
					return false;
				}
				band.made.push_back(out);
				VTFrameProcessorFrame *f = [[VTFrameProcessorFrame alloc] initWithBuffer:out
					presentationTimeStamp:CMTimeMake((int64_t)std::llround((counter - 1 + p) * scale), scale)];
				if(!f)
				{
					setError(error, "could not wrap an output picture");
					return false;
				}
				[destinations addObject:f];
				[phase_list addObject:@(p)];
			}
			VTLowLatencyFrameInterpolationParameters *parameters = [[VTLowLatencyFrameInterpolationParameters alloc]
				initWithSourceFrame:source previousFrame:previous interpolationPhase:phase_list destinationFrames:destinations];
			if(!parameters)
			{
				setError(error, "invalid interpolation parameters");
				return false;
			}
			NSError *ns_error = nil;
			if(![band.processor processWithParameters:parameters error:&ns_error])
			{
				setError(error, std::string("Apple frame interpolation failed: ")
					+ (ns_error ? ns_error.localizedDescription.UTF8String : "unknown error"));
				return false;
			}
		}
		return true;
	}

	bool makePair(std::string *error)
	{
		dropMade();
		bool ok = true;
		if(bands.size() == 1)
		{
			ok = makeBand(bands[0], error);
			if(!ok && band_pixel_limit <= 0)
			{
				// the system took the whole picture and then could not work on it: bands from now on
				whole_picture_failed = true;
			}
		}
		else
		{
			// each band has its own session, so they can work at the same time
			std::mutex error_mutex;
			std::string first_error;
			bool *ok_ptr = &ok;
			std::string *first_error_ptr = &first_error;
			std::mutex *error_mutex_ptr = &error_mutex;
			Impl *self = this;
			dispatch_apply(bands.size(), dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^(size_t i) {
				std::string band_error;
				if(!self->makeBand(self->bands[i], &band_error))
				{
					std::lock_guard<std::mutex> lock(*error_mutex_ptr);
					if(*ok_ptr)
						*first_error_ptr = band_error;
					*ok_ptr = false;
				}
			});
			if(!ok)
				setError(error, first_error);
		}
		made_valid = ok;
		return ok;
	}

	// Writes generated frame number `index` of the current pair into `dst`, stitching the bands.
	void copyOut(size_t index, const Nv12Mut &dst)
	{
		std::vector<PlaneReader> luma(bands.size()), chroma(bands.size());
		for(size_t i = 0; i < bands.size(); i++)
		{
			CVPixelBufferRef pb = bands[i].made[index];
			CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
			luma[i].base = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
			luma[i].stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
			chroma[i].base = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
			chroma[i].stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
		}
		for(int plane = 0; plane < 2; plane++)
		{
			const int div = plane ? 2 : 1;
			const std::vector<PlaneReader> &src = plane ? chroma : luma;
			uint8_t *out_base = plane ? dst.uv : dst.y;
			const int out_stride = plane ? dst.uv_stride : dst.y_stride;
			for(int row = 0; row < h / div; row++)
			{
				const int luma_row = row * div;
				const size_t k = row_band[(size_t)luma_row];
				const int weight = row_next_weight[(size_t)luma_row];
				const uint8_t *a = src[k].base + (size_t)(row - bands[k].top / div) * src[k].stride;
				uint8_t *o = out_base + (size_t)row * out_stride;
				if(weight == 0)
				{
					memcpy(o, a, (size_t)w);
					continue;
				}
				const uint8_t *b = src[k + 1].base + (size_t)(row - bands[k + 1].top / div) * src[k + 1].stride;
				const int keep = 256 - weight;
				for(int x = 0; x < w; x++)
					o[x] = (uint8_t)((a[x] * keep + b[x] * weight + 128) >> 8);
			}
		}
		for(Band &band : bands)
			CVPixelBufferUnlockBaseAddress(band.made[index], kCVPixelBufferLock_ReadOnly);
	}
};

AppleInterpolator::AppleInterpolator() : d(new Impl) {}

AppleInterpolator::~AppleInterpolator()
{
	d->closeSession();
}

bool AppleInterpolator::supported()
{
	if(@available(macOS 26.0, *))
		return VTLowLatencyFrameInterpolationConfiguration.isSupported;
	return false;
}

bool AppleInterpolator::init(const Config &config, std::string *error)
{
	if(!supported())
	{
		setError(error, "Apple frame interpolation needs macOS 26 or newer on Apple silicon");
		return false;
	}
	d->closeSession();
	d->frames_between = config.frames_between >= 3 ? 3 : 1;
	d->band_pixel_limit = config.band_pixel_limit > 0 ? config.band_pixel_limit : 0;
	d->whole_picture_failed = false;
	d->color_set = false;
	return true;
}

bool AppleInterpolator::prepare(int width, int height, std::string *error)
{
	if(width <= 0 || height <= 0 || (width % 2) || (height % 2))
	{
		setError(error, "invalid picture size");
		return false;
	}
	if(width == d->w && height == d->h && !d->bands.empty())
		return true;
	return d->openSession(width, height, error);
}

std::string AppleInterpolator::gpuName() const
{
	if(d->bands.size() > 1)
		return "Apple (VideoToolbox, " + std::to_string(d->bands.size()) + " bands)";
	return "Apple (VideoToolbox)";
}

int AppleInterpolator::bands() const
{
	return (int)d->bands.size();
}

bool AppleInterpolator::push(const Nv12View &frame, const ColorInfo &color, std::string *error)
{
	if(!frame.valid() || (frame.width % 2) || (frame.height % 2))
	{
		setError(error, "invalid frame");
		return false;
	}
	const bool wrong_mode = d->whole_picture_failed && d->band_pixel_limit <= 0 && d->bands.size() == 1
		&& (int64_t)d->w * d->h > DEFAULT_BAND_PIXELS;
	if(frame.width != d->w || frame.height != d->h || d->bands.empty() || wrong_mode)
	{
		if(!d->openSession(frame.width, frame.height, error))
			return false;
	}
	if(!d->color_set || color != d->color)
	{
		// another colour description: the frames before it do not belong with this one.
		// The sessions do not depend on it and stay open.
		d->releaseFrames();
		d->color = color;
		d->color_set = true;
	}
	std::vector<CVPixelBufferRef> fresh(d->bands.size(), nullptr);
	for(size_t i = 0; i < d->bands.size(); i++)
	{
		if(CVPixelBufferPoolCreatePixelBuffer(nullptr, d->source_pool, &fresh[i]) != kCVReturnSuccess || !fresh[i])
		{
			for(CVPixelBufferRef pb : fresh)
				if(pb)
					CVPixelBufferRelease(pb);
			setError(error, "could not allocate a source picture");
			return false;
		}
	}
	for(size_t i = 0; i < d->bands.size(); i++)
	{
		Impl::Band &band = d->bands[i];
		copyIn(frame, band.top, d->band_height, fresh[i]);
		tagColor(fresh[i], color);
		if(band.prev)
			CVPixelBufferRelease(band.prev);
		band.prev = band.cur;
		band.cur = fresh[i];
	}
	d->counter++;
	d->dropMade();
	return true;
}

bool AppleInterpolator::ready() const
{
	return !d->bands.empty() && d->bands[0].prev && d->bands[0].cur;
}

bool AppleInterpolator::interpolate(float t, const Nv12Mut &out, InterpolateTiming *timing, std::string *error, float)
{
	const auto start = std::chrono::steady_clock::now();
	if(!ready())
	{
		setError(error, "two frames are needed before interpolating");
		return false;
	}
	if(!out.valid() || out.width != d->w || out.height != d->h)
	{
		setError(error, "output frame does not match the stream size");
		return false;
	}
	if(!d->made_valid && !d->makePair(error))
	{
		d->dropMade();
		return false;
	}
	// the generated frame closest to the wanted time
	size_t best = 0;
	for(size_t i = 1; i < d->phases.size(); i++)
		if(std::abs(d->phases[i] - t) < std::abs(d->phases[best] - t))
			best = i;
	d->copyOut(best, out);
	if(timing)
		timing->total_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
	return true;
}

void AppleInterpolator::reset()
{
	d->releaseFrames();
}

} // namespace robzfg
