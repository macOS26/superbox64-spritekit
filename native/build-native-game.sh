#!/bin/bash
# Compile a SuperBox64 SpriteKit game STRAIGHT to a native binary. No wasm,
# no wasmtime, no webview. Embedded Swift end to end: the game source, the
# framework modules, Box2D v3 as plain C, and the SDL3 backend link into one
# executable. The same GameScene.swift that ships on the web.
#
#   GAME_SRC=path/to/sources GAME_MAIN=path/to/native-main.swift \
#   OUT=mygame ./build-native-game.sh
#
# GAME_SRC files are compiled with the framework modules; KitABI calls
# resolve at link time to native/sdl3-backend.swift. Functions a game never
# touches are stubbed automatically from the KitABI header.
set -euo pipefail
cd "$(dirname "$0")"
FW="$(cd .. && pwd)"
GAME_SRC="${GAME_SRC:?set GAME_SRC to the game source directory}"
GAME_MAIN="${GAME_MAIN:?set GAME_MAIN to the native main.swift}"
OUT="${OUT:-game-native}"
ASSETS_DIR="${ASSETS_DIR:-}"
TC="$(dirname "$(dirname "$(TOOLCHAINS=${SWIFT_TOOLCHAIN:-org.swift.6.3.2-release} xcrun --toolchain swift -f swiftc)")")"
B="$(mktemp -d)"
trap 'rm -rf "$B"' EXIT

EMB=(-enable-experimental-feature Embedded -wmo -Osize -parse-as-library
     -target arm64-apple-macos14
     -Xcc -fmodule-map-file="$FW/Sources/KitABI/include/module.modulemap"
     -Xcc -fmodule-map-file="$FW/Sources/CBox2D/include/module.modulemap"
     -Xcc -fmodule-map-file="$PWD/CSDL3/module.modulemap"
     -Xcc -I/opt/homebrew/include
     -I "$FW/Sources/KitABI/include" -I "$FW/Sources/CBox2D/include" -I "$PWD/CSDL3"
     -I "$B/mod")

export TOOLCHAINS="${SWIFT_TOOLCHAIN:-org.swift.6.3.2-release}"
mkdir -p "$B/mod" "$B/box2d" "$B/src"

echo "→ Box2D v3 (pure C, native)"
for c in "$FW"/Sources/CBox2D/src/*.c; do
  clang -c -O2 -DNDEBUG -ffunction-sections -I "$FW/Sources/CBox2D/include" -I "$FW/Sources/CBox2D/src" \
    -target arm64-apple-macos14 "$c" -o "$B/box2d/$(basename "$c" .c).o"
done

echo "→ framework modules"
build_mod() {
  local m="$1"
  mkdir -p "$B/src/$m"
  for f in "$FW/Sources/$m"/*.swift; do
    sed -e 's/@MainActor//g' -e 's/@preconcurrency//g' "$f" > "$B/src/$m/$(basename "$f")"
  done
  xcrun --toolchain swift swiftc "${EMB[@]}" -module-name "$m" \
    -emit-module -emit-module-path "$B/mod/$m.swiftmodule" \
    -c "$B/src/$m"/*.swift -o "$B/mod/$m.o"
}
for m in SpriteKit AppKit GameplayKit GameController; do echo "  $m"; build_mod "$m"; done

echo "→ game + backend + main (one module)"
mkdir -p "$B/src/game"
for f in "$GAME_SRC"/*.swift; do
  sed -e 's/@MainActor//g' "$f" > "$B/src/game/$(basename "$f")"
done
cp sdl3-backend.swift "$B/src/game/"
cp "$GAME_MAIN" "$B/src/game/native-main.swift"
xcrun --toolchain swift swiftc "${EMB[@]}" -module-name GameNative \
  -c "$B/src/game"/*.swift -o "$B/mod/game.o"

echo "→ assets (baked into the binary when ASSETS_DIR is set)"
python3 - "$ASSETS_DIR" "$B/assets.c" <<'PYEOF'
import os, sys
src, out = sys.argv[1], sys.argv[2]
lines = ["#include <stdint.h>"]
entries = []
if src and os.path.isdir(src):
    for i, name in enumerate(sorted(os.listdir(src))):
        if not name.endswith(".wav"):
            continue
        data = open(os.path.join(src, name), "rb").read()
        lines.append(f"static const unsigned char a{i}[] = {{{','.join(str(b) for b in data)}}};")
        entries.append((name, f"a{i}", len(data)))
lines.append("static const struct { const char *n; const unsigned char *d; uint32_t l; } tbl[] = {")
for name, sym, ln in entries:
    lines.append(f'    {{"{name}", {sym}, {ln}}},')
lines.append("};")
lines.append("""const unsigned char *kit_asset_data(const char *name, uint32_t *len) {
    for (unsigned i = 0; i < sizeof(tbl) / sizeof(tbl[0]); i++) {
        const char *a = tbl[i].n, *b = name;
        while (*a && *a == *b) { a++; b++; }
        if (*a == *b) { *len = tbl[i].l; return tbl[i].d; }
    }
    *len = 0;
    return 0;
}""")
open(out, "w").write("\n".join(lines) + "\n")
total = sum(e[2] for e in entries)
print(f"  {len(entries)} assets baked in ({total} bytes)")
PYEOF
clang -c -O2 -target arm64-apple-macos14 "$B/assets.c" -o "$B/mod/assets.o"

echo "→ stubs (Embedded strtod + untouched KitABI surface)"
python3 - "$FW/Sources/KitABI/include/KitABI.h" "$B/stubs.c" <<'PYEOF'
import re, sys
hdr, out = sys.argv[1], sys.argv[2]
text = open(hdr).read()
protos = re.findall(r"WABI\s+([^;]+);", text)
implemented = {
    "js_log", "gfx_clear", "gfx_save", "gfx_restore", "gfx_translate",
    "gfx_rotate", "gfx_scale", "gfx_set_alpha", "gfx_stroke_poly",
    "gfx_fill_poly", "gfx_fill_circle", "gfx_stroke_circle", "gfx_fill_rect",
    "gfx_stroke_rect", "evt_poll", "snd_by_name", "snd_play", "store_get",
    "store_set", "gp_connected",
}
lines = ['#include "KitABI.h"', "#include <stdlib.h>",
         "double _swift_stdlib_strtod_clocale(const char *str, char **end) { return strtod(str, end); }"]
for p in protos:
    p = " ".join(p.split())
    m = re.match(r"([A-Za-z0-9_*\s]+?)\s*\b([a-z_0-9]+)\s*\(", p)
    if not m:
        continue
    ret, name = m.group(1).strip(), m.group(2)
    if name in implemented:
        continue
    body = "{}" if ret == "void" else "{ return 0; }"
    lines.append(p + " " + body)
open(out, "w").write("\n".join(lines) + "\n")
print(f"  {len(lines) - 3} stubbed")
PYEOF
clang -c -O2 -I "$FW/Sources/KitABI/include" -target arm64-apple-macos14 "$B/stubs.c" -o "$B/mod/stubs.o"
clang -c -O2 -I "$FW/Sources/KitABI/include" -target arm64-apple-macos14 "$FW/Sources/KitABI/shim.c" -o "$B/mod/shim.o"

echo "→ link"
SDL_LINK=(-L /opt/homebrew/lib -lSDL3)
if [ -f "$PWD/vendor/libSDL3.a" ]; then
  # static minimal SDL3 baked in: single-file binary, only used subsystems
  SDL_LINK=("$PWD/vendor/libSDL3.a"
            -framework Cocoa -framework QuartzCore -framework Metal
            -framework IOKit -framework CoreVideo -framework CoreAudio
            -framework AudioToolbox -framework GameController
            -framework ForceFeedback -framework Carbon -framework CoreHaptics
            -framework CoreMedia -framework UniformTypeIdentifiers
            -liconv)
fi
clang -target arm64-apple-macos14 -o "$OUT" \
  "$B"/mod/*.o "$B"/box2d/*.o \
  "${SDL_LINK[@]}" \
  "$TC/lib/swift/embedded/arm64-apple-macos/libswiftUnicodeDataTables.a" \
  -dead_strip

echo "✓ $OUT ($(stat -f%z "$OUT") bytes) - native, no wasm, same game source"
