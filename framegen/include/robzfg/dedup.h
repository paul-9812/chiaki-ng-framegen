// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Robz Play frame generation - repeated-frame detection.
//
// A PS5 streams at 60 fps even when the game renders 30: every game frame then
// arrives twice. The copy is re-encoded, so it is close to, but rarely
// bit-identical with, the first one: the encoder keeps refining parts of the
// picture. Interpolating between a frame and its copy produces judder, so copies
// have to be recognised and dropped first.
//
// A fixed "how many pixels changed" threshold cannot tell an encoder refinement
// from a small real movement. What does separate them is scale: a copy differs
// from its original far less than a new game frame differs from the previous one.
// The detector therefore tracks how much new frames typically change (the "motion
// level") and calls a frame a copy when it changed only a small fraction of that.

#ifndef ROBZFG_DEDUP_H
#define ROBZFG_DEDUP_H

#include <cstdint>
#include <vector>

#include "frame.h"

namespace robzfg
{

struct FrameDifference
{
	// Mean absolute luma difference over the sampled pixels, in 8-bit levels.
	double mean_abs_diff = 0.0;
	// Share of sampled luma pixels whose value moved by more than the pixel threshold (0..1).
	double changed_ratio = 0.0;
	// False for the first frame or after a format change: nothing to compare against.
	bool comparable = false;
};

class DuplicateDetector
{
public:
	struct Config
	{
		// A sampled pixel counts as changed when its luma moved by more than this many levels.
		int pixel_threshold = 6;
		// Sampling step in pixels, both directions. 2 looks at a quarter of the luma plane.
		int sample_step = 2;
		// Below this mean difference a frame is a copy no matter what came before.
		double identical_level = 0.02;
		// A frame is a copy when its mean difference is below this fraction of the motion level.
		double copy_fraction = 0.25;
		// The motion level never drops below this, so near-still pictures do not flap.
		double min_motion_level = 0.12;
		// The motion level is a running average of how much new frames changed.
		// Share of each new frame's difference that goes into the average.
		double motion_tracking = 0.3;
		// A single frame counts for at most this multiple of the current level (cuts, flashes).
		double motion_spike_limit = 2.5;
		// Per-frame decay, so the level comes back down after motion stops abruptly.
		double motion_decay = 0.93;
	};

	DuplicateDetector();
	explicit DuplicateDetector(const Config &config);

	// Compares `frame` with the reference (the last frame accepted as new).
	FrameDifference measure(const Nv12View &frame) const;

	// Decides whether a measured frame repeats the reference and updates the motion level.
	// Call exactly once per incoming frame, in order.
	bool classify(const FrameDifference &diff);

	// Stores `frame` as the new reference. Call for every frame classify() found to be new.
	void accept(const Nv12View &frame);

	void reset();

	double motionLevel() const { return motion_level; }
	const Config &config() const { return cfg; }
	void setConfig(const Config &config) { cfg = config; }

private:
	Config cfg;
	int ref_w = 0;
	int ref_h = 0;
	int ref_step = 0;
	int samples_w = 0;
	int samples_h = 0;
	std::vector<uint8_t> reference; // sub-sampled luma of the last accepted frame
	double motion_level = 0.0;
};

} // namespace robzfg

#endif // ROBZFG_DEDUP_H
