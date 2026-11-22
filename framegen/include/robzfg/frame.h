// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Robz Play frame generation - plain frame views shared by every component.

#ifndef ROBZFG_FRAME_H
#define ROBZFG_FRAME_H

#include <cstdint>

namespace robzfg
{

// YCbCr -> RGB matrix of the video signal.
enum class ColorMatrix
{
	BT709,
	BT601,
};

struct ColorInfo
{
	ColorMatrix matrix = ColorMatrix::BT709;
	bool full_range = false;

	bool operator==(const ColorInfo &o) const { return matrix == o.matrix && full_range == o.full_range; }
	bool operator!=(const ColorInfo &o) const { return !(*this == o); }
};

// 8-bit 4:2:0 picture in NV12 layout: a luma plane followed by an interleaved
// Cb/Cr plane at half resolution. Strides are in bytes and may exceed the width.
struct Nv12View
{
	int width = 0;
	int height = 0;
	const uint8_t *y = nullptr;
	int y_stride = 0;
	const uint8_t *uv = nullptr;
	int uv_stride = 0;

	bool valid() const { return width > 0 && height > 0 && y && uv && y_stride >= width && uv_stride >= width; }
};

struct Nv12Mut
{
	int width = 0;
	int height = 0;
	uint8_t *y = nullptr;
	int y_stride = 0;
	uint8_t *uv = nullptr;
	int uv_stride = 0;

	bool valid() const { return width > 0 && height > 0 && y && uv && y_stride >= width && uv_stride >= width; }
};

} // namespace robzfg

#endif // ROBZFG_FRAME_H
