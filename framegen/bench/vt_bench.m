// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Benchmark: Apple VTLowLatencyFrameInterpolation (macOS 26+), 30 -> 60 fps use case.
// Measures wall time of one synchronous "generate the in-between frame" call and checks
// that the output really is a motion-compensated midpoint (not a copy or a blend).
//
// build: clang -fobjc-arc -mmacosx-version-min=26.0 -O2 vt_bench.m -o vt_bench \
//          -framework Foundation -framework VideoToolbox -framework CoreVideo -framework CoreMedia \
//          -framework CoreImage -framework CoreGraphics -framework Metal
//
// usage: vt_bench <width> <height> <iterations> <mode> [dump_dir]
//   burst           back-to-back calls (throughput)
//   paced           one call every 33.3 ms, like a live 30 fps source (what a game does)
//   spatial         burst, with the processor's built-in 2x upscale (output is 2x the input size)
//   frc, frcq       the older, quality-oriented VTFrameRateConversion API (normal / quality), for comparison
//   strips          1920x1080 in three overlapping 1920x480 bands, one after the other, back to back
//   stripspaced     the same, one frame every 33.3 ms
//   stripspar       the three bands at the same time, back to back
//   stripsparpaced  the three bands at the same time, one frame every 33.3 ms
// (width and height are ignored by the strips modes)
//
// With dump_dir, one generated frame and its two real neighbours are written there as JPEG.

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <VideoToolbox/VideoToolbox.h>
#import <VideoToolbox/VTFrameProcessor.h>
#import <VideoToolbox/VTFrameProcessor_LowLatencyFrameInterpolation.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now_ms(void) { return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }

static uint32_t rng_state = 0x12345678u;
static inline uint32_t rnd(void)
{
	rng_state ^= rng_state << 13;
	rng_state ^= rng_state >> 17;
	rng_state ^= rng_state << 5;
	return rng_state;
}

typedef struct
{
	int w, h;
	float s;      // scale relative to 1080p
	int dx;       // background pan per source frame, pixels (even)
	int sq_step;  // square speed per source frame, pixels (even)
	int sq;       // square size
	int hx, hy, hw, hh; // static HUD rectangle
	uint8_t *tex; // w*h luma texture
} Scene;

static int even(int v) { return (v % 2) ? v + 1 : v; }

static void scene_init(Scene *sc, int w, int h)
{
	sc->w = w;
	sc->h = h;
	sc->s = h / 1080.0f;
	sc->dx = even((int)lroundf(12 * sc->s));
	sc->sq_step = even((int)lroundf(40 * sc->s));
	sc->sq = even((int)(120 * sc->s));
	sc->hw = (int)(240 * sc->s);
	sc->hh = (int)(140 * sc->s);
	sc->hx = w - (int)(300 * sc->s);
	sc->hy = h - (int)(200 * sc->s);
	// keep the square's whole travel (30 steps) left of the HUD, whatever the aspect ratio
	int max_step = ((sc->hx - sc->sq - 16) / 30) & ~1;
	if(sc->sq_step > max_step)
		sc->sq_step = max_step;
	sc->tex = malloc((size_t)w * h);
	float *acc = calloc((size_t)w * h, sizeof(float));
	const int cells[3] = {96, 24, 6};
	const float amps[3] = {0.55f, 0.30f, 0.15f};
	for(int o = 0; o < 3; o++)
	{
		int c = (int)(cells[o] * sc->s);
		if(c < 2)
			c = 2;
		int gw = w / c + 2, gh = h / c + 2;
		float *g = malloc(sizeof(float) * (size_t)gw * gh);
		for(int i = 0; i < gw * gh; i++)
			g[i] = (rnd() & 0xffff) / 65535.0f;
		for(int y = 0; y < h; y++)
		{
			int gy = y / c;
			float fy = (y % c) / (float)c;
			for(int x = 0; x < w; x++)
			{
				int gx = x / c;
				float fx = (x % c) / (float)c;
				float a = g[gy * gw + gx], b = g[gy * gw + gx + 1];
				float cc = g[(gy + 1) * gw + gx], d = g[(gy + 1) * gw + gx + 1];
				acc[(size_t)y * w + x] += amps[o] * ((a * (1 - fx) + b * fx) * (1 - fy) + (cc * (1 - fx) + d * fx) * fy);
			}
		}
		free(g);
	}
	for(size_t i = 0; i < (size_t)w * h; i++)
		sc->tex[i] = (uint8_t)(40 + acc[i] * 160.0f);
	free(acc);
}

// triangle wave 0..30..0 so the pan never wraps: frame index -> scene position
static int tri(int i)
{
	int p = i % 60;
	return p < 30 ? p : 60 - p;
}

static void scene_fill(const Scene *sc, CVPixelBufferRef pb, int k)
{
	CVPixelBufferLockBaseAddress(pb, 0);
	uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
	size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
	uint8_t *uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
	size_t uvs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
	int w = sc->w, h = sc->h;
	int off = k * sc->dx; // < w by construction (max 30 * dx)
	for(int r = 0; r < h; r++)
	{
		const uint8_t *src = sc->tex + (size_t)r * w;
		memcpy(y + r * ys, src + off, (size_t)(w - off));
		memcpy(y + r * ys + (w - off), src, (size_t)off);
	}
	for(int r = 0; r < h / 2; r++)
		memset(uv + r * uvs, 128, (size_t)w);
	// moving square (bright, reddish)
	int sx = k * sc->sq_step, sy = h / 2;
	for(int r = sy; r < sy + sc->sq; r++)
		memset(y + r * ys + sx, 235, (size_t)sc->sq);
	for(int r = sy / 2; r < (sy + sc->sq) / 2; r++)
		for(int x = sx / 2; x < (sx + sc->sq) / 2; x++)
		{
			uv[r * uvs + 2 * x] = 100;
			uv[r * uvs + 2 * x + 1] = 190;
		}
	// static HUD: random (non-periodic) hard-edged blocks, like glyphs on a minimap.
	// A periodic pattern would be ambiguous: shifted by one period it looks the same.
	int stripe = (int)(6 * sc->s);
	if(stripe < 2)
		stripe = 2;
	for(int r = sc->hy; r < sc->hy + sc->hh; r++)
		for(int x = sc->hx; x < sc->hx + sc->hw; x++)
		{
			uint32_t bx = (uint32_t)((x - sc->hx) / stripe), by = (uint32_t)((r - sc->hy) / stripe);
			uint32_t hsh = (bx * 73856093u) ^ (by * 19349663u);
			hsh ^= hsh >> 13;
			hsh *= 0x5bd1e995u;
			hsh ^= hsh >> 15;
			y[r * ys + x] = (hsh & 1) ? 235 : 16;
		}
	CVPixelBufferUnlockBaseAddress(pb, 0);
}

typedef struct
{
	int bg_shift;        // measured background shift of the generated frame relative to the previous frame
	double sq_center;    // measured centre of the bright square (x), -1 if not found
	int sq_width;        // bright pixels found on the probe row
	double hud_mad;      // mean abs difference of the HUD area vs. the source frame
} Check;

// `scale` = output size / input size (1, or 2 in spatial mode)
static Check check_output(const Scene *sc, CVPixelBufferRef out, CVPixelBufferRef prev, CVPixelBufferRef cur, int scale)
{
	Check c = {0, -1, 0, 0};
	CVPixelBufferLockBaseAddress(out, kCVPixelBufferLock_ReadOnly);
	CVPixelBufferLockBaseAddress(prev, kCVPixelBufferLock_ReadOnly);
	CVPixelBufferLockBaseAddress(cur, kCVPixelBufferLock_ReadOnly);
	const uint8_t *o = CVPixelBufferGetBaseAddressOfPlane(out, 0);
	size_t os = CVPixelBufferGetBytesPerRowOfPlane(out, 0);
	const uint8_t *p = CVPixelBufferGetBaseAddressOfPlane(prev, 0);
	size_t ps = CVPixelBufferGetBytesPerRowOfPlane(prev, 0);
	const uint8_t *q = CVPixelBufferGetBaseAddressOfPlane(cur, 0);
	size_t qs = CVPixelBufferGetBytesPerRowOfPlane(cur, 0);
	int w = sc->w, h = sc->h;

	// 1. background: which horizontal shift of the previous frame best explains the output?
	int maxd = 2 * sc->dx;
	int x0 = maxd + 8, x1 = w / 2;
	double best = 1e30;
	for(int d = -maxd; d <= maxd; d++)
	{
		double sad = 0;
		for(int rr = 0; rr < 5; rr++)
		{
			int r = h / 4 + rr * 7;
			const uint8_t *orow = o + (size_t)(r * scale) * os;
			const uint8_t *prow = p + (size_t)r * ps;
			for(int x = x0; x < x1; x++)
				sad += abs((int)orow[x * scale] - (int)prow[x + d]);
		}
		if(sad < best)
		{
			best = sad;
			c.bg_shift = d;
		}
	}
	// 2. square: centre of the bright run on a row through the middle of the square
	{
		int r = h / 2 + sc->sq / 2;
		const uint8_t *orow = o + (size_t)(r * scale) * os;
		long sum = 0;
		int n = 0;
		for(int x = 0; x < sc->hx - 8; x++)
			if(orow[x * scale] > 222)
			{
				sum += x;
				n++;
			}
		c.sq_width = n;
		if(n > 0)
			c.sq_center = (double)sum / n;
	}
	// 3. HUD: must look like the source frame's HUD (it does not move)
	{
		double sad = 0;
		long n = 0;
		for(int r = sc->hy + 4; r < sc->hy + sc->hh - 4; r++)
			for(int x = sc->hx + 4; x < sc->hx + sc->hw - 4; x++)
			{
				sad += abs((int)o[(size_t)(r * scale) * os + x * scale] - (int)q[(size_t)r * qs + x]);
				n++;
			}
		c.hud_mad = n ? sad / n : 0;
	}
	CVPixelBufferUnlockBaseAddress(cur, kCVPixelBufferLock_ReadOnly);
	CVPixelBufferUnlockBaseAddress(prev, kCVPixelBufferLock_ReadOnly);
	CVPixelBufferUnlockBaseAddress(out, kCVPixelBufferLock_ReadOnly);
	return c;
}

static void dump_jpeg(CVPixelBufferRef pb, NSString *path)
{
	CIImage *img = [CIImage imageWithCVPixelBuffer:pb];
	CIContext *ctx = [CIContext context];
	CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	NSError *e = nil;
	if(![ctx writeJPEGRepresentationOfImage:img toURL:[NSURL fileURLWithPath:path] colorSpace:cs options:@{} error:&e])
		fprintf(stderr, "dump failed: %s\n", [[e description] UTF8String]);
	CGColorSpaceRelease(cs);
}

static int cmp_double(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return x < y ? -1 : (x > y ? 1 : 0);
}

// ---------------------------------------------------------------------------------------
// 1080p through the 921600-pixel limit: three overlapping 1920x480 strips, each interpolated
// by its own session, then stitched with a feathered seam. Timed: split + 3 calls + stitch.
// ---------------------------------------------------------------------------------------
#define NSTRIPS 3
#define FULL_W 1920
#define FULL_H 1080
#define STRIP_H 480
static const int strip_top[NSTRIPS] = {0, 300, 600};
#define FEATHER 64 // rows blended in the middle of each 180-row overlap

static void split_strips(CVPixelBufferRef full, CVPixelBufferRef strips[NSTRIPS])
{
	CVPixelBufferLockBaseAddress(full, kCVPixelBufferLock_ReadOnly);
	for(int p = 0; p < 2; p++)
	{
		const uint8_t *src = CVPixelBufferGetBaseAddressOfPlane(full, p);
		size_t ss = CVPixelBufferGetBytesPerRowOfPlane(full, p);
		int div = p ? 2 : 1;
		for(int s = 0; s < NSTRIPS; s++)
		{
			if(p == 0)
				CVPixelBufferLockBaseAddress(strips[s], 0);
			uint8_t *dst = CVPixelBufferGetBaseAddressOfPlane(strips[s], p);
			size_t ds = CVPixelBufferGetBytesPerRowOfPlane(strips[s], p);
			for(int r = 0; r < STRIP_H / div; r++)
				memcpy(dst + r * ds, src + (size_t)(strip_top[s] / div + r) * ss, FULL_W);
			if(p == 1)
				CVPixelBufferUnlockBaseAddress(strips[s], 0);
		}
	}
	CVPixelBufferUnlockBaseAddress(full, kCVPixelBufferLock_ReadOnly);
}

// Which strip(s) own output row r (in plane rows; div = 1 luma, 2 chroma)?
// Returns the lower strip index and the weight (0..256) of the next strip.
static inline void row_owner(int r_luma, int *s, int *wnext)
{
	*s = 0;
	*wnext = 0;
	for(int k = 0; k < NSTRIPS - 1; k++)
	{
		int ov0 = strip_top[k + 1], ov1 = strip_top[k] + STRIP_H; // overlap rows [ov0, ov1)
		int f0 = (ov0 + ov1) / 2 - FEATHER / 2, f1 = f0 + FEATHER;
		if(r_luma < f0)
		{
			*s = k;
			return;
		}
		if(r_luma < f1)
		{
			*s = k;
			*wnext = (int)(((r_luma - f0) * 256 + 128) / FEATHER);
			return;
		}
		*s = k + 1;
	}
}

static void stitch_strips(CVPixelBufferRef strips[NSTRIPS], CVPixelBufferRef full)
{
	CVPixelBufferLockBaseAddress(full, 0);
	for(int s = 0; s < NSTRIPS; s++)
		CVPixelBufferLockBaseAddress(strips[s], kCVPixelBufferLock_ReadOnly);
	for(int p = 0; p < 2; p++)
	{
		int div = p ? 2 : 1;
		uint8_t *dst = CVPixelBufferGetBaseAddressOfPlane(full, p);
		size_t ds = CVPixelBufferGetBytesPerRowOfPlane(full, p);
		const uint8_t *sb[NSTRIPS];
		size_t ss[NSTRIPS];
		for(int s = 0; s < NSTRIPS; s++)
		{
			sb[s] = CVPixelBufferGetBaseAddressOfPlane(strips[s], p);
			ss[s] = CVPixelBufferGetBytesPerRowOfPlane(strips[s], p);
		}
		for(int r = 0; r < FULL_H / div; r++)
		{
			int s, wn;
			row_owner(r * div, &s, &wn);
			const uint8_t *a = sb[s] + (size_t)(r - strip_top[s] / div) * ss[s];
			uint8_t *o = dst + (size_t)r * ds;
			if(wn == 0)
				memcpy(o, a, FULL_W);
			else
			{
				const uint8_t *b = sb[s + 1] + (size_t)(r - strip_top[s + 1] / div) * ss[s + 1];
				int wa = 256 - wn;
				for(int x = 0; x < FULL_W; x++)
					o[x] = (uint8_t)((a[x] * wa + b[x] * wn + 128) >> 8);
			}
		}
	}
	for(int s = 0; s < NSTRIPS; s++)
		CVPixelBufferUnlockBaseAddress(strips[s], kCVPixelBufferLock_ReadOnly);
	CVPixelBufferUnlockBaseAddress(full, 0);
}

// how much do neighbouring strips disagree where they overlap? (mean abs luma difference)
static double seam_disagreement(CVPixelBufferRef strips[NSTRIPS])
{
	double sad = 0;
	long n = 0;
	for(int k = 0; k < NSTRIPS - 1; k++)
	{
		CVPixelBufferLockBaseAddress(strips[k], kCVPixelBufferLock_ReadOnly);
		CVPixelBufferLockBaseAddress(strips[k + 1], kCVPixelBufferLock_ReadOnly);
		const uint8_t *a = CVPixelBufferGetBaseAddressOfPlane(strips[k], 0);
		size_t as = CVPixelBufferGetBytesPerRowOfPlane(strips[k], 0);
		const uint8_t *b = CVPixelBufferGetBaseAddressOfPlane(strips[k + 1], 0);
		size_t bs = CVPixelBufferGetBytesPerRowOfPlane(strips[k + 1], 0);
		int ov0 = strip_top[k + 1], ov1 = strip_top[k] + STRIP_H;
		int f0 = (ov0 + ov1) / 2 - FEATHER / 2;
		for(int r = f0; r < f0 + FEATHER; r++) // only the rows that are actually blended
			for(int x = 0; x < FULL_W; x += 2)
			{
				sad += abs((int)a[(size_t)(r - strip_top[k]) * as + x] - (int)b[(size_t)(r - strip_top[k + 1]) * bs + x]);
				n++;
			}
		CVPixelBufferUnlockBaseAddress(strips[k + 1], kCVPixelBufferLock_ReadOnly);
		CVPixelBufferUnlockBaseAddress(strips[k], kCVPixelBufferLock_ReadOnly);
	}
	return n ? sad / n : 0;
}

static int run_strips(int iters, BOOL paced, BOOL parallel, NSString *dumpDir)
{
	Scene sc;
	scene_init(&sc, FULL_W, FULL_H);
	NSDictionary *fullAttrs = @{
		(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
		(id)kCVPixelBufferWidthKey : @(FULL_W),
		(id)kCVPixelBufferHeightKey : @(FULL_H),
		(id)kCVPixelBufferIOSurfacePropertiesKey : @{}
	};
	CVPixelBufferPoolRef fullPool = NULL, stripPool = NULL;
	CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)fullAttrs, &fullPool);
	VTLowLatencyFrameInterpolationConfiguration *cfg =
		[[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:FULL_W frameHeight:STRIP_H numberOfInterpolatedFrames:1];
	if(!cfg)
	{
		printf("strip configuration rejected\n");
		return 1;
	}
	CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)cfg.sourcePixelBufferAttributes, &stripPool);
	VTFrameProcessor *procs[NSTRIPS];
	double t0 = now_ms();
	for(int s = 0; s < NSTRIPS; s++)
	{
		NSError *err = nil;
		procs[s] = [[VTFrameProcessor alloc] init];
		if(![procs[s] startSessionWithConfiguration:cfg error:&err] || err)
		{
			printf("strip %d: startSession failed: %s\n", s, [[err localizedDescription] UTF8String]);
			return 1;
		}
	}
	double start_ms = now_ms() - t0;

	CVPixelBufferRef prevFull = NULL, prevStrip[NSTRIPS];
	CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, fullPool, &prevFull);
	scene_fill(&sc, prevFull, tri(0));
	for(int s = 0; s < NSTRIPS; s++)
		CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, stripPool, &prevStrip[s]);
	split_strips(prevFull, prevStrip);

	const int warm = 10;
	double *times = malloc(sizeof(double) * (size_t)iters);
	double *t_split = malloc(sizeof(double) * (size_t)iters), *t_proc = malloc(sizeof(double) * (size_t)iters), *t_stitch = malloc(sizeof(double) * (size_t)iters);
	int nt = 0, checked = 0, bg_ok = 0, sq_found = 0;
	double sq_err_sum = 0, sq_width_sum = 0, hud_sum = 0, seam_sum = 0;
	__block int failures = 0;
	const double period = 1000.0 / 30.0;
	double origin = now_ms() + 50.0;
	dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);

	for(int i = 0; i < iters; i++)
	{
		@autoreleasepool
		{
			int ka = tri(i), kb = tri(i + 1);
			CVPixelBufferRef curFull = NULL, outFull = NULL;
			CVPixelBufferRef curStrip[NSTRIPS], dstStrip[NSTRIPS];
			CVPixelBufferRef *curStripP = curStrip, *dstStripP = dstStrip, *prevStripP = prevStrip;
			VTFrameProcessor *__strong *procsP = procs;
			CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, fullPool, &curFull);
			CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, fullPool, &outFull);
			for(int s = 0; s < NSTRIPS; s++)
			{
				CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, stripPool, &curStrip[s]);
				CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, stripPool, &dstStrip[s]);
			}
			scene_fill(&sc, curFull, kb);
			if(paced)
			{
				double wait = origin + i * period - now_ms();
				if(wait > 0)
				{
					struct timespec ts = {(time_t)(wait / 1000.0), (long)(fmod(wait, 1000.0) * 1e6)};
					nanosleep(&ts, NULL);
				}
			}
			double a = now_ms();
			split_strips(curFull, curStrip);
			double b = now_ms();
			void (^one)(size_t) = ^(size_t s) {
				VTFrameProcessorFrame *fs = [[VTFrameProcessorFrame alloc] initWithBuffer:curStripP[s] presentationTimeStamp:CMTimeMake((i + 1) * 20, 600)];
				VTFrameProcessorFrame *fp = [[VTFrameProcessorFrame alloc] initWithBuffer:prevStripP[s] presentationTimeStamp:CMTimeMake(i * 20, 600)];
				VTFrameProcessorFrame *fd = [[VTFrameProcessorFrame alloc] initWithBuffer:dstStripP[s] presentationTimeStamp:CMTimeMake(i * 20 + 10, 600)];
				VTLowLatencyFrameInterpolationParameters *params =
					[[VTLowLatencyFrameInterpolationParameters alloc] initWithSourceFrame:fs previousFrame:fp interpolationPhase:@[@0.5f] destinationFrames:@[fd]];
				NSError *e = nil;
				if(!params || ![procsP[s] processWithParameters:params error:&e])
				{
					@synchronized(cfg)
					{
						failures++;
						if(failures <= 3)
							printf("strip %zu failed at %d: %s\n", s, i, e ? [[e localizedDescription] UTF8String] : "parameters rejected");
					}
				}
			};
			if(parallel)
				dispatch_apply(NSTRIPS, q, one);
			else
				for(size_t s = 0; s < NSTRIPS; s++)
					one(s);
			double c = now_ms();
			stitch_strips(dstStrip, outFull);
			double d = now_ms();

			if(i >= warm)
			{
				times[nt] = d - a;
				t_split[nt] = b - a;
				t_proc[nt] = c - b;
				t_stitch[nt] = d - c;
				nt++;
			}
			Check ch = check_output(&sc, outFull, prevFull, curFull, 1);
			int expected_shift = (kb - ka) * sc.dx / 2;
			checked++;
			if(ch.bg_shift == expected_shift)
				bg_ok++;
			if(ch.sq_center >= 0)
			{
				sq_found++;
				sq_err_sum += fabs(ch.sq_center - ((ka + kb) * sc.sq_step / 2.0 + sc.sq / 2.0 - 0.5));
				sq_width_sum += ch.sq_width;
			}
			hud_sum += ch.hud_mad;
			seam_sum += seam_disagreement(dstStrip);
			if(dumpDir && i == 20)
			{
				dump_jpeg(prevFull, [dumpDir stringByAppendingPathComponent:@"1080_1_real_previous.jpg"]);
				dump_jpeg(outFull, [dumpDir stringByAppendingPathComponent:@"1080_2_generated_3_bands.jpg"]);
				dump_jpeg(curFull, [dumpDir stringByAppendingPathComponent:@"1080_3_real_next.jpg"]);
			}
			CVPixelBufferRelease(prevFull);
			prevFull = curFull;
			CVPixelBufferRelease(outFull);
			for(int s = 0; s < NSTRIPS; s++)
			{
				CVPixelBufferRelease(prevStrip[s]);
				prevStrip[s] = curStrip[s];
				CVPixelBufferRelease(dstStrip[s]);
			}
		}
	}
	for(int s = 0; s < NSTRIPS; s++)
		[procs[s] endSession];

	printf("1920x1080 in 3 strips of 1920x480  %s%s  iterations=%d  failures=%d  3 sessions started in %.0f ms\n",
		parallel ? "parallel" : "sequential", paced ? " paced@30fps" : " burst", iters, failures, start_ms);
	if(nt > 0)
	{
		double s_split = 0, s_proc = 0, s_stitch = 0, sum = 0;
		int over16 = 0, over25 = 0, over33 = 0;
		for(int i = 0; i < nt; i++)
		{
			s_split += t_split[i];
			s_proc += t_proc[i];
			s_stitch += t_stitch[i];
			sum += times[i];
			if(times[i] > 16.667)
				over16++;
			if(times[i] > 25.0)
				over25++;
			if(times[i] > 33.333)
				over33++;
		}
		qsort(times, (size_t)nt, sizeof(double), cmp_double);
		printf("  ms per generated 1080p frame (split + 3 calls + stitch): min %.2f  median %.2f  mean %.2f  p95 %.2f  p99 %.2f  max %.2f   (>16.7: %d, >25: %d, >33.3: %d of %d)\n",
			times[0], times[nt / 2], sum / nt, times[(int)(nt * 0.95)], times[(int)(nt * 0.99)], times[nt - 1], over16, over25, over33, nt);
		printf("  breakdown (mean): split %.2f ms, interpolation %.2f ms, stitch %.2f ms\n", s_split / nt, s_proc / nt, s_stitch / nt);
	}
	if(checked > 0)
		printf("  correctness: background at the true midpoint in %d of %d frames; square found in %d, mean position error %.2f px, mean width %.0f px (real %d); HUD mean abs diff %.2f levels; seam disagreement %.2f levels\n",
			bg_ok, checked, sq_found, sq_found ? sq_err_sum / sq_found : -1.0, sq_found ? sq_width_sum / sq_found : 0.0, sc.sq, hud_sum / checked, seam_sum / checked);
	return 0;
}

int main(int argc, char **argv)
{
	@autoreleasepool
	{
		if(argc < 5)
		{
			fprintf(stderr, "usage: vt_bench <width> <height> <iterations> <burst|paced|spatial|frc|frcq|strips|stripspaced|stripspar|stripsparpaced> [dump_dir]\n");
			return 2;
		}
		int w = atoi(argv[1]), h = atoi(argv[2]), iters = atoi(argv[3]);
		const char *mode = argv[4];
		if(strncmp(mode, "strips", 6) == 0)
			return run_strips(iters, strstr(mode, "paced") != NULL, strstr(mode, "par") != NULL, argc > 5 ? [NSString stringWithUTF8String:argv[5]] : nil);
		BOOL paced = strcmp(mode, "paced") == 0 || strcmp(mode, "frcpaced") == 0;
		BOOL spatial = strcmp(mode, "spatial") == 0;
		// frc / frcq: the older, quality-oriented VTFrameRateConversion API (normal / quality)
		BOOL frc = strncmp(mode, "frc", 3) == 0;
		BOOL frcQuality = strcmp(mode, "frcq") == 0;
		NSString *dumpDir = argc > 5 ? [NSString stringWithUTF8String:argv[5]] : nil;
		int scale = spatial ? 2 : 1;

		id<VTFrameProcessorConfiguration> cfg = nil;
		if(frc)
		{
			if(![VTFrameRateConversionConfiguration isSupported])
			{
				printf("VTFrameRateConversion is not supported on this system\n");
				return 1;
			}
			cfg = [[VTFrameRateConversionConfiguration alloc] initWithFrameWidth:w frameHeight:h usePrecomputedFlow:NO
				qualityPrioritization:frcQuality ? VTFrameRateConversionConfigurationQualityPrioritizationQuality : VTFrameRateConversionConfigurationQualityPrioritizationNormal
				revision:[VTFrameRateConversionConfiguration defaultRevision]];
		}
		else
		{
			if(![VTLowLatencyFrameInterpolationConfiguration isSupported])
			{
				printf("VTLowLatencyFrameInterpolation is not supported on this system\n");
				return 1;
			}
			cfg = spatial
				? [[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:w frameHeight:h spatialScaleFactor:2]
				: [[VTLowLatencyFrameInterpolationConfiguration alloc] initWithFrameWidth:w frameHeight:h numberOfInterpolatedFrames:1];
		}
		if(!cfg)
		{
			printf("%dx%d %s: configuration rejected\n", w, h, mode);
			return 1;
		}
		// force 8-bit NV12 (video range): the synthetic scene writes that layout
		NSMutableDictionary *srcAttrs = [cfg.sourcePixelBufferAttributes mutableCopy];
		NSMutableDictionary *dstAttrs = [cfg.destinationPixelBufferAttributes mutableCopy];
		srcAttrs[(id)kCVPixelBufferPixelFormatTypeKey] = @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
		dstAttrs[(id)kCVPixelBufferPixelFormatTypeKey] = @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
		CVPixelBufferPoolRef srcPool = NULL, dstPool = NULL;
		CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)srcAttrs, &srcPool);
		CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)dstAttrs, &dstPool);
		if(!srcPool || !dstPool)
		{
			printf("pool creation failed\n");
			return 1;
		}

		Scene sc;
		scene_init(&sc, w, h);

		VTFrameProcessor *proc = [[VTFrameProcessor alloc] init];
		NSError *err = nil;
		double t0 = now_ms();
		// startSession can return YES and still report why the processor did not come up
		if(![proc startSessionWithConfiguration:cfg error:&err] || err)
		{
			printf("%dx%d mode=%s: startSession failed: %s\n", w, h, mode, [[err localizedDescription] UTF8String]);
			return 1;
		}
		double start_ms = now_ms() - t0;

		const int warm = 10;
		double *times = malloc(sizeof(double) * (size_t)iters);
		int nt = 0;
		int checked = 0, bg_ok = 0, sq_found = 0;
		double sq_err_sum = 0, sq_width_sum = 0, hud_sum = 0;
		int failures = 0;

		CVPixelBufferRef prev = NULL;
		CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, srcPool, &prev);
		scene_fill(&sc, prev, tri(0));
		const double period = 1000.0 / 30.0;
		double origin = now_ms() + 50.0;

		for(int i = 0; i < iters; i++)
		{
			@autoreleasepool
			{
				int ka = tri(i), kb = tri(i + 1);
				CVPixelBufferRef cur = NULL, dst = NULL, dst2 = NULL;
				CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, srcPool, &cur);
				CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, dstPool, &dst);
				if(spatial)
					CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, dstPool, &dst2);
				scene_fill(&sc, cur, kb);

				if(paced)
				{
					double due = origin + i * period;
					double wait = due - now_ms();
					if(wait > 0)
					{
						struct timespec ts = {(time_t)(wait / 1000.0), (long)(fmod(wait, 1000.0) * 1e6)};
						nanosleep(&ts, NULL);
					}
				}

				double a = now_ms();
				VTFrameProcessorFrame *fs = [[VTFrameProcessorFrame alloc] initWithBuffer:cur presentationTimeStamp:CMTimeMake((i + 1) * 20, 600)];
				VTFrameProcessorFrame *fp = [[VTFrameProcessorFrame alloc] initWithBuffer:prev presentationTimeStamp:CMTimeMake(i * 20, 600)];
				VTFrameProcessorFrame *fd = [[VTFrameProcessorFrame alloc] initWithBuffer:dst presentationTimeStamp:CMTimeMake(i * 20 + 10, 600)];
				NSArray<VTFrameProcessorFrame *> *dests = @[fd];
				if(spatial)
				{
					VTFrameProcessorFrame *fd2 = [[VTFrameProcessorFrame alloc] initWithBuffer:dst2 presentationTimeStamp:CMTimeMake((i + 1) * 20, 600)];
					dests = @[fd, fd2];
				}
				id<VTFrameProcessorParameters> params = nil;
				if(frc)
					params = [[VTFrameRateConversionParameters alloc] initWithSourceFrame:fp nextFrame:fs opticalFlow:nil interpolationPhase:@[@0.5f]
						submissionMode:VTFrameRateConversionParametersSubmissionModeSequential destinationFrames:dests];
				else
					params = [[VTLowLatencyFrameInterpolationParameters alloc] initWithSourceFrame:fs previousFrame:fp interpolationPhase:@[@0.5f] destinationFrames:dests];
				err = nil;
				BOOL ok = params && [proc processWithParameters:params error:&err];
				double b = now_ms();

				if(!ok)
				{
					failures++;
					if(failures <= 3)
						printf("process failed at %d: %s\n", i, params ? [[err description] UTF8String] : "parameters rejected");
				}
				else
				{
					if(i >= warm)
						times[nt++] = b - a;
					Check c = check_output(&sc, dst, prev, cur, scale);
					int expected_shift = (kb - ka) * sc.dx / 2;
					checked++;
					if(c.bg_shift == expected_shift)
						bg_ok++;
					if(c.sq_center >= 0)
					{
						double expect = (ka + kb) * sc.sq_step / 2.0 + sc.sq / 2.0 - 0.5;
						sq_found++;
						sq_err_sum += fabs(c.sq_center - expect);
						sq_width_sum += c.sq_width;
					}
					hud_sum += c.hud_mad;
					if(dumpDir && i == 20)
					{
						dump_jpeg(prev, [dumpDir stringByAppendingPathComponent:@"1_real_previous.jpg"]);
						dump_jpeg(dst, [dumpDir stringByAppendingPathComponent:@"2_generated.jpg"]);
						dump_jpeg(cur, [dumpDir stringByAppendingPathComponent:@"3_real_next.jpg"]);
						printf("sample i=20: bg shift %d (expected %d), square centre %.1f (expected %.1f), square width %d (real %d), HUD diff %.2f\n",
							c.bg_shift, expected_shift, c.sq_center, (ka + kb) * sc.sq_step / 2.0 + sc.sq / 2.0 - 0.5, c.sq_width, sc.sq, c.hud_mad);
					}
				}
				CVPixelBufferRelease(prev);
				prev = cur;
				CVPixelBufferRelease(dst);
				if(dst2)
					CVPixelBufferRelease(dst2);
			}
		}
		[proc endSession];

		printf("%dx%d -> %dx%d  mode=%s  iterations=%d  failures=%d  session start (model load) %.0f ms\n",
			w, h, w * scale, h * scale, mode, iters, failures, start_ms);
		if(nt > 0)
		{
			qsort(times, (size_t)nt, sizeof(double), cmp_double);
			double sum = 0;
			int over16 = 0, over33 = 0;
			for(int i = 0; i < nt; i++)
			{
				sum += times[i];
				if(times[i] > 16.667)
					over16++;
				if(times[i] > 33.333)
					over33++;
			}
			printf("  ms per generated frame: min %.2f  median %.2f  mean %.2f  p95 %.2f  p99 %.2f  max %.2f   (>16.7ms: %d of %d, >33.3ms: %d)\n",
				times[0], times[nt / 2], sum / nt, times[(int)(nt * 0.95)], times[(int)(nt * 0.99)], times[nt - 1], over16, nt, over33);
		}
		if(checked > 0)
			printf("  correctness: background at the true midpoint in %d of %d frames; square found in %d, mean position error %.2f px, mean width %.0f px (real %d); HUD mean abs diff %.2f levels\n",
				bg_ok, checked, sq_found, sq_found ? sq_err_sum / sq_found : -1.0, sq_found ? sq_width_sum / sq_found : 0.0, sc.sq, hud_sum / checked);
	}
	return 0;
}
