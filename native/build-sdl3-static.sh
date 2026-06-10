#!/bin/bash
# Minimal STATIC SDL3 for single-file game binaries: video + render + audio +
# events + joystick/gamepad only. Everything a 2D arcade game never touches
# (camera, sensors, haptics, GPU compute, dialogs, vulkan) is compiled out.
set -euo pipefail
cd "$(dirname "$0")"
VER="${SDL_VER:-$(pkg-config --modversion sdl3 2>/dev/null || echo 3.2.24)}"
[ -f "vendor/libSDL3.a" ] && { echo "✓ vendor/libSDL3.a exists"; exit 0; }
mkdir -p vendor
SRC="vendor/SDL-src"
[ -d "$SRC" ] || git clone --depth 1 --branch "release-$VER" https://github.com/libsdl-org/SDL "$SRC"
cmake -S "$SRC" -B vendor/build -DCMAKE_BUILD_TYPE=MinSizeRel \
  -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST_LIBRARY=OFF \
  -DSDL_CAMERA=OFF -DSDL_SENSOR=OFF -DSDL_HAPTIC=OFF -DSDL_GPU=OFF \
  -DSDL_VULKAN=OFF -DSDL_DIALOG=OFF -DSDL_POWER=OFF -DSDL_OPENGL=OFF -DSDL_OPENGLES=OFF \
  -DSDL_JOYSTICK=OFF -DSDL_HIDAPI=OFF -DSDL_RENDER_GPU=OFF \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 >/dev/null
cmake --build vendor/build -j 8 >/dev/null
cp vendor/build/libSDL3.a vendor/libSDL3.a
echo "✓ vendor/libSDL3.a ($(stat -f%z vendor/libSDL3.a) bytes, subsystems trimmed)"
