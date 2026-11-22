#!/bin/bash
# Builds chiaki-ng with frame generation on macOS (Apple silicon) and runs the frame
# generation tests.
#
#   scripts/build-macos-framegen.sh            configure, build the app and the tests, run the tests
#   scripts/build-macos-framegen.sh selftest   also open the app in self-test mode; it feeds
#                                              itself synthetic 30 fps video, prints what came
#                                              out and closes
#
# Needs the Xcode Command Line Tools (full Xcode is not needed) and these Homebrew packages:
#
#   brew install qt@6 ffmpeg pkgconf opus openssl@3 cmake ninja nasm protobuf@29 speexdsp \
#                libplacebo python-setuptools json-c miniupnpc libevent molten-vk
#
# (sdl2-compat comes in with ffmpeg.) The build's code generator needs the Python protobuf
# module; the script keeps it in .venv inside the repository instead of installing it into
# your Python.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
BREW="$(brew --prefix)"

if [ ! -f "$ROOT/third-party/nanopb/CMakeLists.txt" ]; then
	git -C "$ROOT" submodule update --init --recursive
fi

if [ ! -x "$ROOT/.venv/bin/python3" ]; then
	python3 -m venv "$ROOT/.venv"
	"$ROOT/.venv/bin/pip" install --quiet 'protobuf>=5,<6' setuptools
fi
export PATH="$ROOT/.venv/bin:$PATH"

# One thing differs from the project's own macOS recipe, so that nothing on the system has to
# be changed. Homebrew links OpenSSL 4 into its shared include folder, and the bundled curl
# needs OpenSSL 3. The official recipe unlinks OpenSSL 4. Here CMake is pointed at openssl@3,
# and Opus is taken from its own folder instead of the shared include folder: found there, it
# put the OpenSSL 4 headers in front of the OpenSSL 3 ones for the library's crypto code.
cmake -S "$ROOT" -B "$BUILD" -G Ninja \
	-DCMAKE_BUILD_TYPE=Release \
	-DCHIAKI_ENABLE_CLI=OFF \
	-DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF \
	-DOPENSSL_ROOT_DIR="$BREW/opt/openssl@3" \
	-DOPENSSL_INCLUDE_DIR="$BREW/opt/openssl@3/include" \
	-DOPENSSL_CRYPTO_LIBRARY="$BREW/opt/openssl@3/lib/libcrypto.dylib" \
	-DOPENSSL_SSL_LIBRARY="$BREW/opt/openssl@3/lib/libssl.dylib" \
	-DOpus_INCLUDE_DIRS="$BREW/opt/opus/include" \
	-DOpus_LIBRARIES="$BREW/opt/opus/lib/libopus.dylib" \
	-DCMAKE_PREFIX_PATH="$BREW/opt/openssl@3;$BREW/opt/qt@6;$BREW/opt/protobuf@29" \
	-DPYTHON_EXECUTABLE="$ROOT/.venv/bin/python3" \
	-DPython_EXECUTABLE="$ROOT/.venv/bin/python3"

cmake --build "$BUILD" --target chiaki framegen-engine-test framegen-stage-test

# While Apple's models load, the system prints a lot of chatter on stderr; keep the results.
(cd "$BUILD" && ctest -R framegen --output-on-failure 2>&1 | grep -v -E 'Resolved compile flags|^\(|^\s+"",|SpatialSplit|^\)')

echo
echo "App: $BUILD/gui/chiaki.app"

if [ "${1:-}" = "selftest" ]; then
	LOG="$(mktemp -t chiaki-framegen-selftest)"
	open -W --env CHIAKI_FRAMEGEN_SELFTEST=quit --stderr "$LOG" --stdout "$LOG" "$BUILD/gui/chiaki.app"
	grep -E "Frame generation" "$LOG" || echo "the self-test printed no result; full log: $LOG"
fi
