// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Tests for the frame generation stage (FrameGenStage): what goes in from the decoder side
// and what comes out towards the renderer, and when.
//
// Frames are fed on the clock, like a console stream, and every frame the stage hands on is
// recorded with the moment it was handed on. A 30 fps game has to come out as an even 60.
//
// Exit code: number of failed checks (0 = all passed). Needs macOS 26+ on Apple silicon.

#include "framegen.h"

#include "synthetic_scene.h"

#include <robzfg/apple_interpolator.h>

#include <chiaki/time.h>

extern "C" {
#include <libavutil/frame.h>
#include <libavutil/pixfmt.h>
}

#include <QCoreApplication>
#include <QEventLoop>
#include <QTimer>

#include <pthread.h>
#include <pthread/qos.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using fgtest::Frame;
using fgtest::Scene;

namespace
{

int failures = 0;
int checks = 0;

void expect(bool ok, const char *test, const std::string &what)
{
	checks++;
	if(!ok)
	{
		failures++;
		printf("    FAIL [%s] %s\n", test, what.c_str());
	}
}

std::string fmt(const char *format, ...)
{
	char buf[512];
	va_list ap;
	va_start(ap, format);
	vsnprintf(buf, sizeof(buf), format, ap);
	va_end(ap);
	return buf;
}

struct Shown
{
	double pts = 0.0;
	uint64_t at_us = 0;
};

struct Fed
{
	double pts = 0.0;
	uint64_t at_us = 0;
};

// Stands in for the renderer: notes every frame the stage hands on, and when.
struct Recorder
{
	std::mutex mutex;
	std::vector<Shown> shown;

	FrameGenStage::PresentFn fn()
	{
		return [this](ChiakiFfmpegFrame frame, int32_t, qint64) {
			Shown s;
			s.pts = frame.pts;
			s.at_us = chiaki_time_now_monotonic_us();
			{
				std::lock_guard<std::mutex> lock(mutex);
				shown.push_back(s);
			}
			av_frame_free(&frame.frame);
		};
	}
	std::vector<Shown> take()
	{
		std::lock_guard<std::mutex> lock(mutex);
		return shown;
	}
};

AVFrame *nv12Frame(const Frame &picture)
{
	AVFrame *frame = av_frame_alloc();
	frame->format = AV_PIX_FMT_NV12;
	frame->width = picture.w;
	frame->height = picture.h;
	if(av_frame_get_buffer(frame, 0) < 0)
	{
		av_frame_free(&frame);
		return nullptr;
	}
	for(int r = 0; r < picture.h; r++)
		memcpy(frame->data[0] + (size_t)r * frame->linesize[0], picture.y.data() + (size_t)r * picture.w, (size_t)picture.w);
	for(int r = 0; r < picture.h / 2; r++)
		memcpy(frame->data[1] + (size_t)r * frame->linesize[1], picture.uv.data() + (size_t)r * picture.w, (size_t)picture.w);
	frame->colorspace = AVCOL_SPC_BT709;
	frame->color_range = AVCOL_RANGE_MPEG;
	return frame;
}

// Waits for an exact moment. Sleeping alone is not exact enough: macOS wakes an ordinary thread
// up to several milliseconds late, and the test would then blame the stage for its own jitter.
void sleepUntil(std::chrono::steady_clock::time_point target)
{
	const auto coarse = target - std::chrono::milliseconds(8);
	if(std::chrono::steady_clock::now() < coarse)
		std::this_thread::sleep_until(coarse);
	while(std::chrono::steady_clock::now() < target)
	{
	}
}

// Feeds `count` frames at `fps`. Frame i shows scene position scene_index(i); a frame that
// shows the same position as the one before it is a re-encoded copy: nearly, not exactly, equal.
std::vector<Fed> feed(FrameGenStage &stage, const Scene &scene, int count, double fps, const std::function<int(int)> &scene_index,
	AVPixelFormat format = AV_PIX_FMT_NV12)
{
	std::vector<Fed> fed;
	Frame picture(scene.w, scene.h);
	const auto begin = std::chrono::steady_clock::now() + std::chrono::milliseconds(20);
	int last_index = INT32_MIN;
	uint32_t noise = 0x2545f491u;
	for(int i = 0; i < count; i++)
	{
		AVFrame *frame = nullptr;
		if(format == AV_PIX_FMT_NV12)
		{
			const int index = scene_index(i);
			scene.fill(picture, index);
			if(index == last_index)
			{
				// what an encoder does to a repeated picture: a few pixels move by one level
				for(size_t p = 0; p < picture.y.size(); p += 37)
				{
					noise ^= noise << 13;
					noise ^= noise >> 17;
					noise ^= noise << 5;
					picture.y[p] = (uint8_t)std::min(235, std::max(16, (int)picture.y[p] + ((noise & 1) ? 1 : -1)));
				}
			}
			last_index = index;
			frame = nv12Frame(picture);
		}
		else
		{
			frame = av_frame_alloc();
			frame->format = format;
			frame->width = scene.w;
			frame->height = scene.h;
			if(av_frame_get_buffer(frame, 0) < 0)
				av_frame_free(&frame);
		}
		if(!frame)
			continue;
		sleepUntil(begin + std::chrono::microseconds((int64_t)(i * 1000000.0 / fps)));
		ChiakiFfmpegFrame chiaki_frame = {};
		chiaki_frame.frame = frame;
		chiaki_frame.pts = i / fps;
		chiaki_frame.duration = 1.0 / fps;
		Fed f;
		f.pts = chiaki_frame.pts;
		f.at_us = chiaki_time_now_monotonic_us();
		fed.push_back(f);
		stage.submit(chiaki_frame, 0, (qint64)f.at_us);
	}
	return fed;
}

double percentile(std::vector<double> values, double p)
{
	if(values.empty())
		return 0.0;
	std::sort(values.begin(), values.end());
	return values[std::min(values.size() - 1, (size_t)(p * values.size()))];
}

bool increasing(const std::vector<Shown> &shown)
{
	for(size_t i = 1; i < shown.size(); i++)
		if(!(shown[i].pts > shown[i - 1].pts))
			return false;
	return true;
}

FrameGenStage::Config configFor(bool enabled, unsigned int stream_fps, const Scene &scene)
{
	FrameGenStage::Config config;
	config.enabled = enabled;
	config.target_fps = 60;
	config.stream_fps = stream_fps;
	config.stream_width = scene.w;
	config.stream_height = scene.h;
	return config;
}

// ------------------------------------------------------------------------------------ tests

// A 30 fps game comes out at an even 60: one generated frame between every two real ones.
void testDoubles30()
{
	const char *name = "30 fps in, even 60 fps out";
	printf("  %s\n", name);
	Scene scene(1920, 1080, 12, 0, true);
	FrameGenStage stage;
	Recorder recorder;
	stage.start(configFor(true, 30, scene), recorder.fn());
	const int count = 105;
	const std::vector<Fed> fed = feed(stage, scene, count, 30.0, [](int i) { return i; });
	std::this_thread::sleep_for(std::chrono::milliseconds(120));
	const double source_fps = stage.sourceFps(), output_fps = stage.outputFps(), generate_ms = stage.generateMs();
	const std::string status = stage.status().toStdString();
	stage.stop();
	const std::vector<Shown> shown = recorder.take();

	printf("    %d frames in, %zu out; reported %.1f fps in, %.1f fps out, %.2f ms per generated frame, status \"%s\"\n",
		count, shown.size(), source_fps, output_fps, generate_ms, status.c_str());
	expect((int)shown.size() >= 2 * count - 24, name, fmt("expected about %d frames out (two per frame in), got %zu", 2 * count, shown.size()));
	expect((int)shown.size() <= 2 * count, name, fmt("more frames out (%zu) than two per frame in", shown.size()));
	expect(increasing(shown), name, "frames must leave in order of their timestamps");
	expect(status == "generating", name, "status should be \"generating\", was \"" + status + "\"");
	expect(std::abs(source_fps - 30.0) <= 3.0, name, fmt("reported source rate should be about 30 fps, was %.1f", source_fps));
	expect(std::abs(output_fps - 60.0) <= 6.0, name, fmt("reported output rate should be about 60 fps, was %.1f", output_fps));

	// evenness, once generation has settled
	std::vector<double> gaps;
	for(size_t i = 41; i < shown.size(); i++)
		gaps.push_back((shown[i].at_us - shown[i - 1].at_us) / 1000.0);
	const double p05 = percentile(gaps, 0.05), p50 = percentile(gaps, 0.5), p95 = percentile(gaps, 0.95);
	printf("    time between frames out: 5%% %.1f ms, median %.1f ms, 95%% %.1f ms (ideal 16.7)\n", p05, p50, p95);
	expect(p50 >= 15.2 && p50 <= 18.2, name, fmt("median time between frames should be about 16.7 ms, was %.1f", p50));
	expect(p05 >= 12.5, name, fmt("frames too close together: 5%% of gaps under %.1f ms (limit 12.5)", p05));
	expect(p95 <= 21.0, name, fmt("frames too far apart: 5%% of gaps over %.1f ms (limit 21.0)", p95));

	if(getenv("FGTEST_VERBOSE"))
	{
		// frame by frame: R = real, G = generated; when it left, counted from the arrival of
		// the real frame it belongs to (a generated frame belongs to the real one after it)
		size_t fi = 0;
		for(size_t i = 100; i < shown.size() && i < 130; i++)
		{
			while(fi < fed.size() && fed[fi].pts < shown[i].pts - 1e-9)
				fi++;
			const bool real = fi < fed.size() && std::abs(fed[fi].pts - shown[i].pts) < 1e-9;
			printf("      %c pts %.4f  left %6.1f ms after its real frame arrived, %5.1f ms after the frame before\n", real ? 'R' : 'G',
				shown[i].pts, fi < fed.size() ? ((double)shown[i].at_us - (double)fed[fi].at_us) / 1000.0 : 0.0,
				(shown[i].at_us - shown[i - 1].at_us) / 1000.0);
		}
	}

	// what it costs: how much later a real frame is shown than it arrived
	std::vector<double> delays;
	size_t f = 0;
	for(const Shown &s : shown)
	{
		while(f < fed.size() && fed[f].pts < s.pts - 1e-9)
			f++;
		if(f < fed.size() && std::abs(fed[f].pts - s.pts) < 1e-9 && s.pts > 1.5)
			delays.push_back((s.at_us - fed[f].at_us) / 1000.0);
	}
	const double delay = percentile(delays, 0.5);
	printf("    a real frame leaves %.1f ms after it arrived (median), worst %.1f ms\n", delay, percentile(delays, 0.999));
	expect(!delays.empty() && delay <= 45.0, name, fmt("real frames should be held at most about 45 ms, median was %.1f", delay));
}

// A PS5 streams 60 fps even when the game renders 30: every game frame arrives twice.
// The copies are dropped, and the result is the same even 60.
void testDropsRepeats()
{
	const char *name = "30 fps game inside a 60 fps stream";
	printf("  %s\n", name);
	Scene scene(1920, 1080, 12, 0, true);
	FrameGenStage stage;
	Recorder recorder;
	stage.start(configFor(true, 60, scene), recorder.fn());
	const int count = 210;
	feed(stage, scene, count, 60.0, [](int i) { return i / 2; });
	std::this_thread::sleep_for(std::chrono::milliseconds(120));
	const double source_fps = stage.sourceFps(), output_fps = stage.outputFps();
	const std::string status = stage.status().toStdString();
	stage.stop();
	const std::vector<Shown> shown = recorder.take();
	const int unique = count / 2;
	if(getenv("FGTEST_VERBOSE"))
	{
		printf("      gaps between frames out, frames 60 to 140 (ms):");
		for(size_t i = 60; i < shown.size() && i < 140; i++)
			printf(" %.1f", (shown[i].at_us - shown[i - 1].at_us) / 1000.0);
		printf("\n");
	}
	printf("    %d frames in (%d different), %zu out; reported %.1f fps in, %.1f fps out, status \"%s\"\n",
		count, unique, shown.size(), source_fps, output_fps, status.c_str());
	expect((int)shown.size() >= 2 * unique - 24 && (int)shown.size() <= 2 * unique + 2, name,
		fmt("expected about %d frames out (two per different frame in), got %zu", 2 * unique, shown.size()));
	expect(increasing(shown), name, "frames must leave in order of their timestamps");
	expect(std::abs(source_fps - 30.0) <= 3.0, name, fmt("reported source rate should be about 30 fps, was %.1f", source_fps));
	expect(std::abs(output_fps - 60.0) <= 6.0, name, fmt("reported output rate should be about 60 fps, was %.1f", output_fps));

	std::vector<double> gaps;
	for(size_t i = 41; i < shown.size(); i++)
		gaps.push_back((shown[i].at_us - shown[i - 1].at_us) / 1000.0);
	const double p05 = percentile(gaps, 0.05), p50 = percentile(gaps, 0.5), p95 = percentile(gaps, 0.95);
	printf("    time between frames out: 5%% %.1f ms, median %.1f ms, 95%% %.1f ms (ideal 16.7)\n", p05, p50, p95);
	expect(p50 >= 15.2 && p50 <= 18.2, name, fmt("median time between frames should be about 16.7 ms, was %.1f", p50));
	expect(p05 >= 12.5, name, fmt("frames too close together: 5%% of gaps under %.1f ms (limit 12.5)", p05));
	expect(p95 <= 21.0, name, fmt("frames too far apart: 5%% of gaps over %.1f ms (limit 21.0)", p95));
}

// Switched off, the stage is not in the way: every frame goes straight on, untouched.
void testDisabled()
{
	const char *name = "switched off: frames pass straight through";
	printf("  %s\n", name);
	Scene scene(1280, 720, 8, 0, true);
	FrameGenStage stage;
	Recorder recorder;
	stage.start(configFor(false, 30, scene), recorder.fn());
	const std::vector<Fed> fed = feed(stage, scene, 20, 30.0, [](int i) { return i; });
	std::this_thread::sleep_for(std::chrono::milliseconds(60));
	stage.stop();
	const std::vector<Shown> shown = recorder.take();
	expect(shown.size() == fed.size(), name, fmt("expected %zu frames out, got %zu", fed.size(), shown.size()));
	bool same = shown.size() == fed.size();
	double worst = 0.0;
	for(size_t i = 0; same && i < shown.size(); i++)
	{
		same = shown[i].pts == fed[i].pts;
		worst = std::max(worst, (shown[i].at_us - fed[i].at_us) / 1000.0);
	}
	expect(same, name, "the same frames, in the same order");
	expect(worst <= 3.0, name, fmt("no frame may be held back when switched off; worst was %.2f ms", worst));
}

// A game that already runs at 60 gets nothing added and loses nothing.
void testAlready60()
{
	const char *name = "already 60 fps: nothing added, nothing dropped";
	printf("  %s\n", name);
	Scene scene(1920, 1080, 12, 0, true);
	FrameGenStage stage;
	Recorder recorder;
	stage.start(configFor(true, 60, scene), recorder.fn());
	const int count = 120;
	feed(stage, scene, count, 60.0, [](int i) { return i; });
	std::this_thread::sleep_for(std::chrono::milliseconds(120));
	stage.stop();
	const std::vector<Shown> shown = recorder.take();
	expect((int)shown.size() == count, name, fmt("expected %d frames out, got %zu", count, shown.size()));
	expect(increasing(shown), name, "frames must leave in order of their timestamps");
}

// Pictures the engine cannot read (10-bit HDR) are shown as they are.
void testUnsupportedFormat()
{
	const char *name = "10-bit pictures pass through";
	printf("  %s\n", name);
	Scene scene(1280, 720, 8, 0, false);
	FrameGenStage stage;
	Recorder recorder;
	stage.start(configFor(true, 30, scene), recorder.fn());
	const int count = 20;
	feed(stage, scene, count, 30.0, [](int i) { return i; }, AV_PIX_FMT_YUV420P10LE);
	std::this_thread::sleep_for(std::chrono::milliseconds(120));
	stage.stop();
	const std::vector<Shown> shown = recorder.take();
	expect((int)shown.size() == count, name, fmt("expected %d frames out, got %zu", count, shown.size()));
	expect(increasing(shown), name, "frames must leave in order of their timestamps");
}

// The built-in self-test (what CHIAKI_FRAMEGEN_SELFTEST=1 runs inside the application) feeds
// synthetic 30 fps video and reports what came out.
void testSelfTestReports()
{
	const char *name = "self-test reports 60 fps";
	printf("  %s\n", name);
	FrameGenStage stage;
	FrameGenStage::Config config;
	config.enabled = true;
	config.target_fps = 60;
	config.stream_fps = 30;
	config.stream_width = 1920;
	config.stream_height = 1080;
	bool finished = false;
	FrameGenStage::SelfTestResult result;
	QEventLoop loop;
	stage.runSelfTest(config, {}, [&](const FrameGenStage::SelfTestResult &r) {
		result = r;
		finished = true;
		loop.quit();
	}, 120);
	QTimer::singleShot(15000, &loop, &QEventLoop::quit); // never hang the test run
	loop.exec();
	expect(finished, name, "the self-test must report back when it is done");
	if(!finished)
		return;
	printf("    %d frames in, %d out, %.1f fps in, %.1f fps out, %.2f ms per generated frame, status \"%s\"\n", result.frames_in,
		result.frames_out, result.source_fps, result.output_fps, result.generate_ms, result.status.toUtf8().constData());
	expect(result.frames_in >= 100 && result.frames_in <= 120, name, fmt("about 120 frames fed, was %d", result.frames_in));
	expect(result.frames_out >= 2 * result.frames_in - 30, name, fmt("about two frames out per frame in, got %d for %d", result.frames_out, result.frames_in));
	expect(std::abs(result.output_fps - 60.0) <= 6.0, name, fmt("output rate should be about 60 fps, was %.1f", result.output_fps));
	expect(result.status == QStringLiteral("generating"), name, "status should be \"generating\", was \"" + result.status.toStdString() + "\"");
	expect(!stage.enabled(), name, "the stage is stopped again after the self-test");
}

// Closing the application in the middle of a self-test must not bring it down: the stage
// stops its own feeder thread.
void testSelfTestAbandoned()
{
	const char *name = "self-test abandoned half way";
	printf("  %s\n", name);
	FrameGenStage::Config config;
	config.enabled = true;
	config.target_fps = 60;
	config.stream_fps = 30;
	config.stream_width = 1280;
	config.stream_height = 720;
	const auto begin = std::chrono::steady_clock::now();
	{
		FrameGenStage stage;
		stage.runSelfTest(config, {}, {}, 240);
		std::this_thread::sleep_for(std::chrono::milliseconds(600));
	} // destroyed while frames are still being fed
	const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - begin).count();
	expect(ms < 2500.0, name, fmt("stopping must not wait for the self-test to run its course; took %.0f ms", ms));
}

} // namespace

int main(int argc, char **argv)
{
	QCoreApplication app(argc, argv);
	// the thread that feeds frames plays the part of the stream: it has to be on time
	pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
	if(!robzfg::AppleInterpolator::supported())
	{
		printf("Apple frame interpolation is not available on this system (needs macOS 26+ on Apple silicon): tests skipped\n");
		return 0;
	}
	printf("Frame generation stage\n");
	testDisabled();
	testUnsupportedFormat();
	testAlready60();
	testDoubles30();
	testDropsRepeats();
	testSelfTestReports();
	testSelfTestAbandoned();
	printf("%d checks, %d failed\n", checks, failures);
	return failures;
}
