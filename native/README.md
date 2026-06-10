# Native backends · the same game, no wasm

SuperBox64 SpriteKit games talk to the platform through one contract: the
KitABI `env` surface (about 100 C functions for graphics, sound, input,
storage). On the web that surface is filled by the wasm-web-kit JS runtime.
It can be filled by anything else, which gives every game three shapes from
ONE source tree:

| Permutation | What runs | What fills KitABI | Ships as |
|---|---|---|---|
| 1. Web | game.wasm in the browser | runtime.js + canvas | a website |
| 2. Cartridge | game.wasm in wasmtime | a native SDL3 host | host + .wasm "ROM" |
| 3. Direct | native machine code | this SDL3 backend, linked in | one binary |

`sdl3-backend.swift` implements the surface on SDL3: a Canvas2D compatible
matrix stack, thick polylines via SDL_RenderGeometry, the SFML event
vocabulary from SDL events, WAV voices mixed on one device, and the
persistence store as a file. It is game agnostic and Embedded Swift clean
(no Swift stdlib, no Foundation).

`build-native-game.sh` produces permutation 3: game source + framework
modules + Box2D v3 (plain C) + this backend, linked into a single native
executable. KitABI functions the game never calls are stubbed automatically
from the header. AsteroidZ builds to a 662 KB binary this way, pixel
identical to its web build, because it IS the same code.

Why this matters: permutation 2 makes wasm files behave like game
cartridges, one host per platform plays every game ever built on the
framework. Permutation 3 skips wasm entirely for stores that want plain
binaries (Steam, itch, consoles), still from 100% common game source. The
web build stays untouched either way; the WABI header attribute only
applies under `__wasm__`.
