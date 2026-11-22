// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Robz Play frame generation - Apple's own frame interpolation (macOS 26+, VideoToolbox
// VTLowLatencyFrameInterpolation). Same calling pattern as RifeInterpolator, so the
// frame generation stage can use either one. Only built on macOS.

#ifndef ROBZFG_APPLE_INTERPOLATOR_H
#define ROBZFG_APPLE_INTERPOLATOR_H

#include <memory>
#include <string>

#include "frame.h"
#include "timing.h" // InterpolateTiming

namespace robzfg
{

class AppleInterpolator
{
public:
	struct Config
	{
		// Frames generated between two real ones: 1 for 60 fps, 3 for 120 fps.
		int frames_between = 1;
		// Largest picture, in pixels, handed to one Apple session. Larger pictures are split
		// into overlapping horizontal bands of at most this size, interpolated side by side
		// and stitched. 0 picks for itself: the whole picture where the system accepts it,
		// otherwise bands of 921600 pixels (what macOS 26.2 accepts, so 1080p takes 3 bands).
		int band_pixel_limit = 0;
	};

	AppleInterpolator();
	~AppleInterpolator();
	AppleInterpolator(const AppleInterpolator &) = delete;
	AppleInterpolator &operator=(const AppleInterpolator &) = delete;

	// True when this Mac and macOS version offer the feature.
	static bool supported();

	bool init(const Config &config, std::string *error = nullptr);
	// Opens Apple's sessions for a picture size ahead of the first frame. Starting them takes
	// from a quarter of a second to several seconds (the first time a program uses a picture
	// size), which would otherwise hold up the first push(). Optional: push() opens them too.
	bool prepare(int width, int height, std::string *error = nullptr);
	std::string gpuName() const;
	// Bands the current picture size is split into; 1 = the whole picture at once, 0 = no
	// picture seen yet.
	int bands() const;

	// Makes `frame` the current frame (the old current becomes the previous one).
	bool push(const Nv12View &frame, const ColorInfo &color, std::string *error = nullptr);
	bool ready() const;
	// Writes the frame at `t` (0 < t < 1) between previous and current. All frames of one
	// pair are made in a single call to Apple's processor and handed out from a cache.
	bool interpolate(float t, const Nv12Mut &out, InterpolateTiming *timing = nullptr, std::string *error = nullptr,
		float field_time = -1.f);
	void reset();

private:
	struct Impl;
	std::unique_ptr<Impl> d;
};

} // namespace robzfg

#endif // ROBZFG_APPLE_INTERPOLATOR_H
