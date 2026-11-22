// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Synthetic video with exactly known motion, for the frame generation tests.
//
// A textured background pans by a fixed number of pixels per frame; optionally a bright
// square crosses it quickly and a block of hard-edged "HUD" stays put. Because the motion is
// known, a test can tell where every part of a generated in-between frame has to be.

#ifndef ROBZFG_TEST_SYNTHETIC_SCENE_H
#define ROBZFG_TEST_SYNTHETIC_SCENE_H

#include "robzfg/frame.h"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace fgtest
{

// An 8-bit NV12 picture in plain memory.
struct Frame
{
	int w = 0, h = 0;
	std::vector<uint8_t> y, uv;

	Frame(int width, int height) : w(width), h(height), y((size_t)width * height), uv((size_t)width * height / 2, 128) {}

	robzfg::Nv12View view() const
	{
		robzfg::Nv12View v;
		v.width = w;
		v.height = h;
		v.y = y.data();
		v.y_stride = w;
		v.uv = uv.data();
		v.uv_stride = w;
		return v;
	}
	robzfg::Nv12Mut mut()
	{
		robzfg::Nv12Mut m;
		m.width = w;
		m.height = h;
		m.y = y.data();
		m.y_stride = w;
		m.uv = uv.data();
		m.uv_stride = w;
		return m;
	}
};

struct Scene
{
	int w, h;
	int dx, dy;   // background pan per source frame (even numbers: the midpoint is a whole pixel)
	bool objects; // moving square + static HUD block
	int sq = 0, sq_step = 0, sq_x0 = 0;
	int hx = 0, hy = 0, hw = 0, hh = 0, block = 2;
	std::vector<uint8_t> tex;

	Scene(int width, int height, int pan_x, int pan_y, bool with_objects) : w(width), h(height), dx(pan_x), dy(pan_y), objects(with_objects)
	{
		const float s = h / 1080.0f;
		sq = ((int)(120 * s)) & ~1;
		sq_step = ((int)(40 * s)) & ~1;
		sq_x0 = ((int)(200 * s)) & ~1;
		hw = (int)(240 * s);
		hh = (int)(140 * s);
		hx = w - (int)(300 * s);
		hy = h - (int)(200 * s);
		block = std::max(2, (int)(6 * s));

		// three octaves of value noise: smooth large shapes plus fine detail
		uint32_t state = 0x12345678u;
		auto rnd = [&state]() {
			state ^= state << 13;
			state ^= state >> 17;
			state ^= state << 5;
			return state;
		};
		std::vector<float> acc((size_t)w * h, 0.f);
		const int cells[3] = {96, 24, 6};
		const float amps[3] = {0.55f, 0.30f, 0.15f};
		for(int o = 0; o < 3; o++)
		{
			const int c = std::max(2, (int)(cells[o] * s));
			const int gw = w / c + 2, gh = h / c + 2;
			std::vector<float> g((size_t)gw * gh);
			for(float &v : g)
				v = (rnd() & 0xffff) / 65535.0f;
			for(int yy = 0; yy < h; yy++)
			{
				const int gy = yy / c;
				const float fy = (yy % c) / (float)c;
				for(int xx = 0; xx < w; xx++)
				{
					const int gx = xx / c;
					const float fx = (xx % c) / (float)c;
					const float a = g[(size_t)gy * gw + gx], b = g[(size_t)gy * gw + gx + 1];
					const float cc = g[(size_t)(gy + 1) * gw + gx], d = g[(size_t)(gy + 1) * gw + gx + 1];
					acc[(size_t)yy * w + xx] += amps[o] * ((a * (1 - fx) + b * fx) * (1 - fy) + (cc * (1 - fx) + d * fx) * fy);
				}
			}
		}
		tex.resize((size_t)w * h);
		for(size_t i = 0; i < tex.size(); i++)
			tex[i] = (uint8_t)(40 + acc[i] * 160.0f);
	}

	// The square moves right for 20 frames and then starts over, so it never leaves the picture.
	int squareX(int k) const { return sq_x0 + (((k % 20) + 20) % 20) * sq_step; }

	// Frame number k: luma(x, y) = tex(x + k*dx, y + k*dy), wrapping around.
	void fill(Frame &f, int k) const
	{
		const int ox = (int)((((int64_t)k * dx) % w + w) % w);
		const int oy = (int)((((int64_t)k * dy) % h + h) % h);
		for(int r = 0; r < h; r++)
		{
			const uint8_t *src = tex.data() + (size_t)((r + oy) % h) * w;
			uint8_t *dst = f.y.data() + (size_t)r * w;
			memcpy(dst, src + ox, (size_t)(w - ox));
			memcpy(dst + (w - ox), src, (size_t)ox);
		}
		std::fill(f.uv.begin(), f.uv.end(), (uint8_t)128);
		if(!objects)
			return;
		const int sx = squareX(k), sy = h / 2;
		for(int r = sy; r < sy + sq; r++)
			memset(f.y.data() + (size_t)r * w + sx, 235, (size_t)sq);
		for(int r = sy / 2; r < (sy + sq) / 2; r++)
			for(int x = sx / 2; x < (sx + sq) / 2; x++)
			{
				f.uv[(size_t)r * w + 2 * x] = 100;
				f.uv[(size_t)r * w + 2 * x + 1] = 190;
			}
		// static HUD: random hard-edged blocks (not periodic, so its motion is unambiguous)
		for(int r = hy; r < hy + hh; r++)
			for(int x = hx; x < hx + hw; x++)
			{
				uint32_t bx = (uint32_t)((x - hx) / block), by = (uint32_t)((r - hy) / block);
				uint32_t hsh = (bx * 73856093u) ^ (by * 19349663u);
				hsh ^= hsh >> 13;
				hsh *= 0x5bd1e995u;
				hsh ^= hsh >> 15;
				f.y[(size_t)r * w + x] = (hsh & 1) ? 235 : 16;
			}
	}
};

// Which shift (sx, sy) makes out(x, y) look most like ref(x + sx, y + sy) inside the window?
inline void bestShift(const Frame &out, const Frame &ref, int x0, int y0, int x1, int y1, int radius, int *best_sx, int *best_sy)
{
	double best = 1e300;
	*best_sx = *best_sy = 0;
	for(int sy = -radius; sy <= radius; sy++)
		for(int sx = -radius; sx <= radius; sx++)
		{
			uint64_t sad = 0;
			for(int y = y0; y < y1; y += 2)
			{
				const uint8_t *o = out.y.data() + (size_t)y * out.w;
				const uint8_t *r = ref.y.data() + (size_t)(y + sy) * ref.w;
				for(int x = x0; x < x1; x += 2)
					sad += (uint64_t)std::abs((int)o[x] - (int)r[x + sx]);
			}
			if((double)sad < best)
			{
				best = (double)sad;
				*best_sx = sx;
				*best_sy = sy;
			}
		}
}

} // namespace fgtest

#endif // ROBZFG_TEST_SYNTHETIC_SCENE_H
