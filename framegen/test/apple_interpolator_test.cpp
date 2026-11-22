// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Tests for the Apple frame interpolation engine (robzfg::AppleInterpolator).
//
// Every test builds a synthetic scene whose motion is known exactly (a textured background
// panning by a fixed number of pixels per frame, a fast bright square, a static HUD block),
// asks the engine for the frame halfway between two real frames, and measures where things
// ended up. A correct in-between frame shows the background shifted by exactly half a step.
//
// Exit code: number of failed tests (0 = all passed). Needs macOS 26+ on Apple silicon.

#include "robzfg/apple_interpolator.h"

#include "synthetic_scene.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <string>
#include <vector>

using robzfg::AppleInterpolator;
using robzfg::ColorInfo;
using robzfg::InterpolateTiming;
using robzfg::Nv12Mut;
using robzfg::Nv12View;
using fgtest::bestShift;
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

// Pushes frames k and k+1 of `scene` and writes the halfway frame into `out`.
bool makeMiddle(AppleInterpolator &engine, const Scene &scene, int k, Frame &prev, Frame &cur, Frame &out, std::string *error,
	double *total_ms = nullptr)
{
	scene.fill(prev, k);
	scene.fill(cur, k + 1);
	const auto begin = std::chrono::steady_clock::now();
	if(!engine.push(prev.view(), ColorInfo(), error))
		return false;
	if(!engine.push(cur.view(), ColorInfo(), error))
		return false;
	InterpolateTiming timing;
	if(!engine.interpolate(0.5f, out.mut(), &timing, error))
		return false;
	if(total_ms)
		*total_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - begin).count();
	return true;
}

// ------------------------------------------------------------------------------------ tests

// The frame between two frames shows the background halfway, and the fast square halfway too.
void testMidpoint(const char *name, int w, int h)
{
	printf("  %s\n", name);
	const float s = h / 1080.0f;
	const int dx = ((int)std::lround(12 * s) + 1) & ~1;
	Scene scene(w, h, dx, 0, true);
	AppleInterpolator engine;
	std::string error;
	AppleInterpolator::Config config;
	expect(engine.init(config, &error), name, "init: " + error);
	Frame prev(w, h), cur(w, h), out(w, h);
	const bool ok = makeMiddle(engine, scene, 3, prev, cur, out, &error);
	expect(ok, name, "interpolate at " + std::to_string(w) + "x" + std::to_string(h) + ": " + error);
	if(!ok)
		return;

	int sx, sy;
	bestShift(out, prev, w / 8, h / 6, w / 2, h / 6 + 60, 2 * dx, &sx, &sy);
	expect(sx == dx / 2 && sy == 0, name, fmt("background should sit at the midpoint (%d, 0), found (%d, %d)", dx / 2, sx, sy));

	// the square: one bright run on the row through its middle, centred halfway
	const int row = h / 2 + scene.sq / 2;
	long sum = 0;
	int n = 0;
	for(int x = 0; x < scene.hx - 8; x++)
		if(out.y[(size_t)row * w + x] > 222)
		{
			sum += x;
			n++;
		}
	const double expected = (scene.squareX(3) + scene.squareX(4)) / 2.0 + scene.sq / 2.0 - 0.5;
	const double centre = n ? (double)sum / n : -1.0;
	expect(n > 0 && std::abs(centre - expected) <= 1.5, name, fmt("square centre should be %.1f, found %.1f", expected, centre));
	expect(std::abs(n - scene.sq) <= std::max(6, scene.sq / 12), name, fmt("square should be %d px wide (one copy, not two ghosts), found %d bright px", scene.sq, n));
}

// Every part of the picture, top to bottom, must move by the same half step: the engine may
// not show bands or seams where it splits the picture internally.
//
// `band_pixel_limit` > 0 forces the engine to split the picture into bands of that size, so the
// band path is tested even on a system that would take the whole picture; `min_bands` is how
// many bands that must give.
void testUniformMotion(const char *name, int w, int h, int dx, int dy, int band_pixel_limit = 0, int min_bands = 0)
{
	printf("  %s\n", name);
	Scene scene(w, h, dx, dy, false);
	AppleInterpolator engine;
	std::string error;
	AppleInterpolator::Config config;
	config.band_pixel_limit = band_pixel_limit;
	expect(engine.init(config, &error), name, "init: " + error);
	Frame prev(w, h), cur(w, h), out(w, h);
	const bool ok = makeMiddle(engine, scene, 2, prev, cur, out, &error);
	expect(ok, name, "interpolate: " + error);
	if(!ok)
		return;
	printf("    picture handled in %d band(s)\n", engine.bands());
	if(min_bands > 0)
		expect(engine.bands() >= min_bands, name, fmt("should be split into at least %d bands, was %d", min_bands, engine.bands()));
	const int radius = std::max(std::abs(dx), std::abs(dy)) + 4;
	int bad = 0;
	std::string detail;
	// a window every 30 rows over the whole height (margins: the search radius, and the
	// texture's own wrap-around line near the bottom and right edges)
	const int y_first = radius + 8, y_last = h - 3 * std::abs(dy) - radius - 40;
	for(int y = y_first; y < y_last; y += 30)
		for(int col = 0; col < 3; col++)
		{
			const int x0 = radius + 16 + col * (w / 4);
			int sx, sy;
			bestShift(out, prev, x0, y, x0 + w / 5, y + 24, radius, &sx, &sy);
			if(sx != dx / 2 || sy != dy / 2)
			{
				bad++;
				if(detail.size() < 300)
					detail += fmt(" [rows %d-%d, x %d: (%d,%d)]", y, y + 24, x0, sx, sy);
			}
		}
	expect(bad == 0, name, fmt("every window should move by (%d, %d); %d windows did not:%s", dx / 2, dy / 2, bad, detail.c_str()));
}

// One generated 1080p frame has to fit well inside the 33 ms between two frames of a 30 fps game.
void testTiming(const char *name, int w, int h, double median_limit_ms, double worst_limit_ms)
{
	printf("  %s\n", name);
	Scene scene(w, h, 12, 0, true);
	AppleInterpolator engine;
	std::string error;
	AppleInterpolator::Config config;
	expect(engine.init(config, &error), name, "init: " + error);
	Frame cur(w, h), out(w, h);
	std::vector<double> ms;
	bool ok = true;
	scene.fill(cur, 0);
	ok = engine.push(cur.view(), ColorInfo(), &error);
	for(int k = 1; ok && k <= 70; k++)
	{
		scene.fill(cur, k % 20);
		const auto begin = std::chrono::steady_clock::now();
		ok = engine.push(cur.view(), ColorInfo(), &error) && engine.interpolate(0.5f, out.mut(), nullptr, &error);
		const double t = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - begin).count();
		if(k > 10) // the first calls set up buffers and pipelines
			ms.push_back(t);
	}
	expect(ok, name, "push + interpolate: " + error);
	if(!ok || ms.empty())
		return;
	std::sort(ms.begin(), ms.end());
	const double median = ms[ms.size() / 2], worst = ms.back();
	printf("    push + interpolate at %dx%d: median %.2f ms, worst %.2f ms (%zu frames)\n", w, h, median, worst, ms.size());
	expect(median <= median_limit_ms, name, fmt("median should be at most %.1f ms, was %.2f ms", median_limit_ms, median));
	expect(worst <= worst_limit_ms, name, fmt("worst should be at most %.1f ms, was %.2f ms", worst_limit_ms, worst));
}

// A change of picture size drops the history and keeps working; reset() drops it too.
void testResizeAndReset(const char *name)
{
	printf("  %s\n", name);
	AppleInterpolator engine;
	std::string error;
	AppleInterpolator::Config config;
	expect(engine.init(config, &error), name, "init: " + error);
	expect(!engine.ready(), name, "a fresh engine has no frames");

	Scene small(1280, 720, 8, 0, true);
	Frame sp(1280, 720), sc(1280, 720), so(1280, 720);
	expect(makeMiddle(engine, small, 1, sp, sc, so, &error), name, "720p: " + error);
	expect(engine.ready(), name, "ready after two frames");

	Scene big(1920, 1080, 12, 0, true);
	Frame bp(1920, 1080), bc(1920, 1080), bo(1920, 1080);
	big.fill(bp, 1);
	expect(engine.push(bp.view(), ColorInfo(), &error), name, "first 1080p push after 720p: " + error);
	expect(!engine.ready(), name, "a new size starts a new history: one frame is not enough");
	big.fill(bc, 2);
	expect(engine.push(bc.view(), ColorInfo(), &error), name, "second 1080p push: " + error);
	expect(engine.ready(), name, "ready after two frames of the new size");
	expect(engine.interpolate(0.5f, bo.mut(), nullptr, &error), name, "1080p after a size change: " + error);

	engine.reset();
	expect(!engine.ready(), name, "reset() drops the history");
	expect(!engine.interpolate(0.5f, bo.mut(), nullptr, &error), name, "interpolate without two frames must fail cleanly");
}

// Opening Apple's sessions takes from a quarter of a second to several seconds (the first time
// a program uses a picture size). prepare() does it ahead of the first frame, so that video
// does not stall when the stream starts; a new colour description must not reopen them either.
void testPrepare(const char *name)
{
	printf("  %s\n", name);
	Scene scene(1920, 1080, 12, 0, true);
	AppleInterpolator engine;
	std::string error;
	AppleInterpolator::Config config;
	expect(engine.init(config, &error), name, "init: " + error);
	expect(engine.bands() == 0, name, "no picture size known before prepare()");
	expect(engine.prepare(1920, 1080, &error), name, "prepare: " + error);
	expect(engine.bands() >= 1, name, "prepare() settles how the picture is handled");
	expect(!engine.ready(), name, "prepare() brings no frames");

	Frame a(1920, 1080), b(1920, 1080), out(1920, 1080);
	scene.fill(a, 1);
	scene.fill(b, 2);
	auto timed = [](const std::function<bool()> &call, bool *ok) {
		const auto begin = std::chrono::steady_clock::now();
		*ok = call();
		return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - begin).count();
	};
	bool ok = false;
	double ms = timed([&]() { return engine.push(a.view(), ColorInfo(), &error); }, &ok);
	expect(ok, name, "first push: " + error);
	expect(ms < 20.0, name, fmt("the first push after prepare() must not open sessions; it took %.1f ms", ms));
	expect(engine.push(b.view(), ColorInfo(), &error) && engine.interpolate(0.5f, out.mut(), nullptr, &error), name, "interpolate after prepare(): " + error);

	ColorInfo other;
	other.matrix = robzfg::ColorMatrix::BT601;
	ms = timed([&]() { return engine.push(a.view(), other, &error); }, &ok);
	expect(ok, name, "push with another colour description: " + error);
	expect(!engine.ready(), name, "another colour description starts a new history");
	expect(ms < 20.0, name, fmt("another colour description must not reopen the sessions; the push took %.1f ms", ms));
	expect(engine.push(b.view(), other, &error) && engine.interpolate(0.5f, out.mut(), nullptr, &error), name, "interpolate after a colour change: " + error);
}

} // namespace

int main()
{
	if(!AppleInterpolator::supported())
	{
		printf("Apple frame interpolation is not available on this system (needs macOS 26+ on Apple silicon): tests skipped\n");
		return 0;
	}
	printf("Apple frame interpolation engine\n");
	testMidpoint("midpoint 720p", 1280, 720);
	testMidpoint("midpoint 1080p", 1920, 1080);
	testUniformMotion("uniform horizontal motion 1080p", 1920, 1080, 12, 0);
	testUniformMotion("uniform vertical motion 1080p", 1920, 1080, 0, 12);
	testUniformMotion("uniform diagonal motion 1080p", 1920, 1080, 12, 8);
	testUniformMotion("uniform vertical motion 720p, forced into bands", 1280, 720, 0, 8, 400000, 3);
	testUniformMotion("uniform diagonal motion 720p, forced into bands", 1280, 720, 8, 6, 400000, 3);
	testResizeAndReset("resize and reset");
	testPrepare("prepare ahead of the first frame");
	testTiming("timing 1080p", 1920, 1080, 25.0, 33.0);
	printf("%d checks, %d failed\n", checks, failures);
	return failures;
}
