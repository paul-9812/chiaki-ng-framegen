# Engine benchmarks

Three small command-line programs that were used to find out what Apple's low-latency frame
interpolation (`VTLowLatencyFrameInterpolation`, macOS 26+) can do on a given Mac, before any
of it went into the application. They are not built by CMake; each file starts with the
`clang` line that builds it.

| File | What it answers |
|---|---|
| `vt_probe.m` | Is the processor supported here? Which picture sizes and pixel formats does it take? |
| `vt_start_session_check.m` | Why does a 1080p session report "Processor is not initialized"? |
| `vt_bench.m` | How long does one generated frame take, and is it really the motion-compensated midpoint? |

`vt_bench` draws a synthetic scene with exactly known motion (a textured background panning,
a fast bright square, a static block standing in for a HUD), so besides timing each call it
can check where things ended up in the generated frame.

## What they showed

MacBook Pro 14" (M4, 10-core GPU, 16 GB), macOS 26.2, on battery with Low Power Mode on,
which is the slowest state the machine can be in:

| Case | Time per generated frame |
|---|---|
| 1280x720, back to back | about 5.3 ms |
| 1280x720, one every 33.3 ms | about 8.7 ms |
| 1920x1080 in one session | refused: "must not exceed 921600" pixels |
| 1920x1080 in three 1920x480 bands, one after the other, one every 33.3 ms | about 19.9 ms |
| 1920x1080 in three bands at the same time, one every 33.3 ms | about 16.8 ms |
| 1920x1080 with `VTFrameRateConversion` (the quality-oriented API) | about 48 ms: too slow for 30 fps |

In every run the background of the generated frame sat at the exact midpoint between the two
real frames, and neighbouring bands disagreed by 0.4 grey levels on average where they
overlap: the seams do not show.

These findings are what the engine in `../src/apple_interpolator.mm` is built on: three
bands for 1080p, an explicit check of the error that `startSession` reports, and the three
sessions running side by side.
