// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Robz Play frame generation - repeated-frame detection.

#include "robzfg/dedup.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>

namespace robzfg
{

DuplicateDetector::DuplicateDetector() = default;

DuplicateDetector::DuplicateDetector(const Config &config) : cfg(config) {}

void DuplicateDetector::reset()
{
	reference.clear();
	ref_w = ref_h = ref_step = 0;
	samples_w = samples_h = 0;
	motion_level = 0.0;
}

void DuplicateDetector::accept(const Nv12View &frame)
{
	if(!frame.valid())
		return;
	const int step = std::max(1, cfg.sample_step);
	ref_w = frame.width;
	ref_h = frame.height;
	ref_step = step;
	samples_w = (frame.width + step - 1) / step;
	samples_h = (frame.height + step - 1) / step;
	reference.resize((size_t)samples_w * samples_h);
	for(int sy = 0; sy < samples_h; sy++)
	{
		const uint8_t *src = frame.y + (size_t)(sy * step) * frame.y_stride;
		uint8_t *dst = reference.data() + (size_t)sy * samples_w;
		if(step == 1)
		{
			memcpy(dst, src, (size_t)samples_w);
			continue;
		}
		for(int sx = 0; sx < samples_w; sx++)
			dst[sx] = src[sx * step];
	}
}

FrameDifference DuplicateDetector::measure(const Nv12View &frame) const
{
	FrameDifference diff;
	const int step = std::max(1, cfg.sample_step);
	if(!frame.valid() || reference.empty() || frame.width != ref_w || frame.height != ref_h || step != ref_step)
		return diff;
	diff.comparable = true;

	const int threshold = cfg.pixel_threshold;
	uint64_t sad = 0;
	uint64_t changed = 0;
	for(int sy = 0; sy < samples_h; sy++)
	{
		const uint8_t *src = frame.y + (size_t)(sy * step) * frame.y_stride;
		const uint8_t *ref = reference.data() + (size_t)sy * samples_w;
		uint32_t row_sad = 0;
		uint32_t row_changed = 0;
		for(int sx = 0; sx < samples_w; sx++)
		{
			const int delta = std::abs((int)src[sx * step] - (int)ref[sx]);
			row_sad += (uint32_t)delta;
			row_changed += delta > threshold ? 1u : 0u;
		}
		sad += row_sad;
		changed += row_changed;
	}

	const double total = (double)samples_w * samples_h;
	diff.mean_abs_diff = total > 0 ? (double)sad / total : 0.0;
	diff.changed_ratio = total > 0 ? (double)changed / total : 0.0;
	return diff;
}

bool DuplicateDetector::classify(const FrameDifference &diff)
{
	if(!diff.comparable)
		return false;

	motion_level *= cfg.motion_decay;

	bool duplicate;
	if(diff.mean_abs_diff <= cfg.identical_level)
		duplicate = true;
	else
		duplicate = diff.mean_abs_diff < cfg.copy_fraction * std::max(motion_level, cfg.min_motion_level);

	if(!duplicate)
	{
		// Follow the typical change of new frames, not its peaks: a cut or a sudden flash is
		// many times larger than ordinary motion, and taking it at face value would make the
		// next ordinary frames look like copies.
		if(motion_level <= 0.0)
			motion_level = diff.mean_abs_diff;
		else
			motion_level += cfg.motion_tracking * (std::min(diff.mean_abs_diff, cfg.motion_spike_limit * motion_level) - motion_level);
	}
	return duplicate;
}

} // namespace robzfg
