// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Frame generation - timing of one interpolate() call.
// (In Robz Play this struct lives in rife_interpolator.h; the RIFE engine is not part of this fork.)

#ifndef ROBZFG_TIMING_H
#define ROBZFG_TIMING_H

namespace robzfg
{

struct InterpolateTiming
{
	double total_ms = 0.0; // wall time of the whole call, including upload and download
};

} // namespace robzfg

#endif // ROBZFG_TIMING_H
