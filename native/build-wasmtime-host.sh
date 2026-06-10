#!/bin/bash
# Build the wasmtime host (permutation 2: wasm cartridge + native SDL3/wasmtime host).
# Requires: SDL3 and wasmtime C libraries installed (brew install sdl3 wasmtime on macOS,
# apt install libSDL3-dev libwasmtime-dev on Linux).
set -euo pipefail
cd "$(dirname "$0")"

# Platform detection for system include/lib paths
detect_sys() {
  case "$(uname -s)" in
    Darwin)
      if [ -d /opt/homebrew/include ]; then
        SYS_INC="/opt/homebrew/include"
        SYS_LIB="/opt/homebrew/lib"
      else
        SYS_INC="/usr/local/include"
        SYS_LIB="/usr/local/lib"
      fi
      ;;
    Linux)
      SYS_INC="/usr/include"
      SYS_LIB="/usr/lib"
      ;;
    *)
      echo "Unsupported platform: $(uname -s)" >&2; exit 1
      ;;
  esac
}
detect_sys

TC="$(dirname "$(dirname "$(TOOLCHAINS=${SWIFT_TOOLCHAIN:-org.swift.6.3.2-release} xcrun --toolchain swift -f swiftc)")")"

export TOOLCHAINS="${SWIFT_TOOLCHAIN:-org.swift.6.3.2-release}"
xcrun --toolchain swift swiftc \
  -enable-experimental-feature Embedded -wmo -Osize -parse-as-library \
  -Xcc -fmodule-map-file="$PWD/CSDL3/module.modulemap" \
  -Xcc -fmodule-map-file="$PWD/CWasmtime/module.modulemap" \
  -Xcc -I"$SYS_INC" \
  -I "$PWD/CSDL3" -I "$PWD/CWasmtime" \
  -L "$SYS_LIB" -lSDL3 -lwasmtime \
  "$TC/lib/swift/embedded/arm64-apple-macos/libswiftUnicodeDataTables.a" \
  wasmtime-host.swift -o asteroidz-wasmtime-host
echo "✓ asteroidz-wasmtime-host ($(stat -f%z asteroidz-wasmtime-host 2>/dev/null || stat -c%s asteroidz-wasmtime-host) bytes, Embedded Swift host)"