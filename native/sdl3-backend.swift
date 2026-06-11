// Permutation 3: NO WASM AT ALL. The game + framework compile straight to a
// native arm64 binary; KitABI's env surface links directly against this SDL3
// backend (the same contract the web runtime and the wasmtime host fill).
// Embedded Swift, no stdlib, no Foundation. Box2D v3 links as plain C.
import CSDL3

let LOGICAL_W: Float = 1920
let LOGICAL_H: Float = 1080
let windowResizable: UInt64 = 0x20
let windowHighPixelDensity: UInt64 = 0x2000

struct Mat {
    var a: Float = 1, b: Float = 0, c: Float = 0, d: Float = 1, e: Float = 0, f: Float = 0

    mutating func mul(_ n: Mat) {
        self = Mat(
            a: a * n.a + c * n.b, b: b * n.a + d * n.b,
            c: a * n.c + c * n.d, d: b * n.c + d * n.d,
            e: a * n.e + c * n.f + e, f: b * n.e + d * n.f + f
        )
    }

    func apply(_ x: Float, _ y: Float) -> SDL_FPoint {
        SDL_FPoint(x: a * x + c * y + e, y: b * x + d * y + f)
    }

    var lengthScale: Float {
        (SDL_sqrtf(a * a + b * b) + SDL_sqrtf(c * c + d * d)) / 2
    }
}

@_silgen_name("kit_asset_data")
func kit_asset_data(_ name: UnsafePointer<CChar>?, _ len: UnsafeMutablePointer<UInt32>?) -> UnsafePointer<UInt8>?

final class Kit {
    static let shared = Kit()
    var window: OpaquePointer? = nil
    var renderer: OpaquePointer? = nil
    var mat = Mat()
    var stack: [Mat] = []
    var alpha: Float = 1
    var events: [(Int32, Int32, Int32, Int32, Int32)] = []
    var soundSpecs: [SDL_AudioSpec] = [SDL_AudioSpec()]
    var soundBufs: [UnsafeMutablePointer<UInt8>?] = [nil]
    var soundLens: [UInt32] = [0]
    var soundNames: [String: Int32] = [:]
    var audioDevice: UInt32 = 0
    var voiceStreams: [OpaquePointer] = []
    var voiceLoops: [Int32] = []
    var voiceIds: [Int32] = []
    var voicePans: [Float] = []
    var nextVoice: Int32 = 1
    var additive = false
    var whiteTex: UnsafeMutablePointer<SDL_Texture>? = nil

    // 1x1 white texture: RenderGeometry honors TEXTURE blend modes, the
    // reliable route to alpha and additive (matchstick crossings brighten)
    func geometryTexture() -> UnsafeMutablePointer<SDL_Texture>? {
        if whiteTex == nil {
            whiteTex = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_RGBA8888,
                                         SDL_TEXTUREACCESS_STATIC, 1, 1)
            var px: UInt32 = 0xFFFFFFFF
            var rect = SDL_Rect(x: 0, y: 0, w: 1, h: 1)
            _ = SDL_UpdateTexture(whiteTex, &rect, &px, 4)
        }
        _ = SDL_SetTextureBlendMode(whiteTex, additive ? SDL_BLENDMODE_ADD : SDL_BLENDMODE_BLEND)
        return whiteTex
    }
    var storeKeys: [String] = []
    var storeVals: [String] = []
    var assetDir = "assets/sfx"
    var storePath = ".native-store.tsv"
    var fullscreen = false

    // RenderGeometry ignores vertex alpha against the backbuffer in practice,
    // so transparency is baked by scaling the color toward black - exact on
    // this game's black background.
    func fcolor(_ rgba: UInt32) -> SDL_FColor {
        let a = Float(rgba & 0xFF) / 255 * alpha
        return SDL_FColor(
            r: Float((rgba >> 24) & 0xFF) / 255 * a,
            g: Float((rgba >> 16) & 0xFF) / 255 * a,
            b: Float((rgba >> 8) & 0xFF) / 255 * a,
            a: 1
        )
    }

    func strokePoly(_ pts: [SDL_FPoint], closed: Bool, thickness: Float, rgba: UInt32) {
        if pts.count < 2 { return }
        // degenerate paths (pathless container shapes) must not leave a dot
        var minX = pts[0].x, maxX = pts[0].x, minY = pts[0].y, maxY = pts[0].y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        if maxX - minX < 0.01, maxY - minY < 0.01 { return }
        let color = fcolor(rgba)
        let w = max(1, thickness * mat.lengthScale) / 2
        var verts = [SDL_Vertex]()
        var idx = [Int32]()
        let segs = closed ? pts.count : pts.count - 1
        for i in 0..<segs {
            let p1 = pts[i]
            let p2 = pts[(i + 1) % pts.count]
            let dx = p2.x - p1.x
            let dy = p2.y - p1.y
            let len = max(SDL_sqrtf(dx * dx + dy * dy), 0.0001)
            let nx = -dy / len * w
            let ny = dx / len * w
            let base = Int32(verts.count)
            verts.append(SDL_Vertex(position: SDL_FPoint(x: p1.x + nx, y: p1.y + ny), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
            verts.append(SDL_Vertex(position: SDL_FPoint(x: p2.x + nx, y: p2.y + ny), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
            verts.append(SDL_Vertex(position: SDL_FPoint(x: p2.x - nx, y: p2.y - ny), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
            verts.append(SDL_Vertex(position: SDL_FPoint(x: p1.x - nx, y: p1.y - ny), color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
            idx.append(base)
            idx.append(base + 1)
            idx.append(base + 2)
            idx.append(base)
            idx.append(base + 2)
            idx.append(base + 3)
        }
        // round joins: a small fan at every vertex seals the segment quads,
        // otherwise corners crack open and shimmer while shapes rotate.
        // Skipped in additive mode where the fan overlapping its own line
        // doubles the brightness into a hot dot at every end.
        for p in additive ? [] : pts {
            let base = Int32(verts.count)
            verts.append(SDL_Vertex(position: p, color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
            for j in 0...8 {
                let t = Float(j) / 8 * 2 * Float.pi
                verts.append(SDL_Vertex(position: SDL_FPoint(x: p.x + w * SDL_cosf(t), y: p.y + w * SDL_sinf(t)),
                                        color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
            }
            for j in 0..<8 {
                idx.append(base)
                idx.append(base + 1 + Int32(j))
                idx.append(base + 2 + Int32(j))
            }
        }
        SDL_RenderGeometry(renderer, geometryTexture(), verts, Int32(verts.count), idx, Int32(idx.count))
    }

    func fillPoly(_ pts: [SDL_FPoint], rgba: UInt32) {
        if pts.count < 3 { return }
        let color = fcolor(rgba)
        var verts = [SDL_Vertex]()
        verts.reserveCapacity(pts.count)
        for p in pts {
            verts.append(SDL_Vertex(position: p, color: color, tex_coord: SDL_FPoint(x: 0, y: 0)))
        }
        var idx = [Int32]()
        for i in 1..<(pts.count - 1) {
            idx.append(0)
            idx.append(Int32(i))
            idx.append(Int32(i + 1))
        }
        SDL_RenderGeometry(renderer, geometryTexture(), verts, Int32(verts.count), idx, Int32(idx.count))
    }

    func circlePts(_ cx: Float, _ cy: Float, _ r: Float) -> [SDL_FPoint] {
        var out = [SDL_FPoint]()
        out.reserveCapacity(32)
        for i in 0..<32 {
            let t = Float(i) / 32 * 2 * Float.pi
            out.append(mat.apply(cx + r * SDL_cosf(t), cy + r * SDL_sinf(t)))
        }
        return out
    }

    func cString(_ p: UnsafePointer<CChar>?, _ len: Int32) -> String {
        guard let p else { return "" }
        var bytes = [UInt8]()
        bytes.reserveCapacity(Int(len) + 1)
        for i in 0..<Int(len) { bytes.append(UInt8(bitPattern: p[i])) }
        bytes.append(0)
        return bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    func loadSound(_ name: String) -> Int32 {
        return loadSoundImpl(name)
    }

    func loadSoundImpl(_ name: String) -> Int32 {
        var base = name
        var lastSlash = -1
        var i = 0
        for ch in base.utf8 {
            if ch == 47 { lastSlash = i }
            i += 1
        }
        if lastSlash >= 0 {
            var bytes = Array(base.utf8)
            bytes.removeFirst(lastSlash + 1)
            bytes.append(0)
            base = bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }
        if let id = soundNames[base] { return id }
        let id = Int32(soundSpecs.count)
        soundNames[base] = id
        var spec = SDL_AudioSpec()
        var buf: UnsafeMutablePointer<UInt8>? = nil
        var len: UInt32 = 0
        // assets baked into the binary take priority; disk is the fallback
        var memLen: UInt32 = 0
        let mem = base.withCString { kit_asset_data($0, &memLen) }
        if let mem, memLen > 0 {
            let io = SDL_IOFromConstMem(mem, Int(memLen))
            _ = SDL_LoadWAV_IO(io, true, &spec, &buf, &len)
        } else {
            let path = assetDir + "/" + base
            _ = path.withCString { SDL_LoadWAV($0, &spec, &buf, &len) }
        }
        soundSpecs.append(spec)
        soundBufs.append(buf)
        soundLens.append(len)
        return id
    }

    @discardableResult
    func play(_ id: Int32, volume: Float, loop: Bool) -> Int32 {
        let i = Int(id)
        guard i > 0, i < soundBufs.count, let buf = soundBufs[i] else { return -1 }
        if audioDevice == 0 {
            audioDevice = SDL_OpenAudioDevice(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, nil)
            guard audioDevice != 0 else { return -1 }
            _ = SDL_ResumeAudioDevice(audioDevice)
        }
        var spec = soundSpecs[i]
        guard let stream = SDL_CreateAudioStream(&spec, nil) else { return -1 }
        _ = SDL_SetAudioStreamGain(stream, max(0, min(1, volume / 100)))
        _ = SDL_BindAudioStream(audioDevice, stream)
        _ = SDL_PutAudioStreamData(stream, buf, Int32(soundLens[i]))
        if !loop { _ = SDL_FlushAudioStream(stream) }
        let voice = nextVoice
        nextVoice += 1
        voiceStreams.append(stream)
        voiceLoops.append(loop ? id : 0)
        voiceIds.append(voice)
        voicePans.append(0)
        return voice
    }

    // Pan by re-encoding the mono source as gain-weighted stereo at put time.
    // Loops refill every buffer, so pan changes land within a buffer's length.
    func putData(_ stream: OpaquePointer, _ soundIdx: Int, pan: Float) {
        guard let buf = soundBufs[soundIdx] else { return }
        var spec = soundSpecs[soundIdx]
        let len = Int(soundLens[soundIdx])
        let isU8 = spec.format == SDL_AUDIO_U8
        let isS16 = spec.format == SDL_AUDIO_S16LE
        if spec.channels == 1, pan != 0, isU8 || isS16 {
            let gl = min(1, 1 - pan)
            let gr = min(1, 1 + pan)
            var stereo = spec
            stereo.channels = 2
            _ = SDL_SetAudioStreamFormat(stream, &stereo, nil)
            if isU8 {
                var out = [UInt8]()
                out.reserveCapacity(len * 2)
                for i in 0..<len {
                    let centered = Float(buf[i]) - 128
                    out.append(UInt8(max(0, min(255, 128 + centered * gl))))
                    out.append(UInt8(max(0, min(255, 128 + centered * gr))))
                }
                _ = out.withUnsafeBufferPointer { SDL_PutAudioStreamData(stream, $0.baseAddress, Int32(out.count)) }
            } else {
                let samples = len / 2
                let src = UnsafeRawPointer(buf)
                var out = [Int16]()
                out.reserveCapacity(samples * 2)
                for i in 0..<samples {
                    let v = Float(src.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                    out.append(Int16(max(-32768, min(32767, v * gl))))
                    out.append(Int16(max(-32768, min(32767, v * gr))))
                }
                _ = out.withUnsafeBufferPointer { SDL_PutAudioStreamData(stream, $0.baseAddress, Int32(out.count * 2)) }
            }
        } else {
            _ = SDL_SetAudioStreamFormat(stream, &spec, nil)
            _ = SDL_PutAudioStreamData(stream, buf, Int32(len))
        }
    }

    func setVoicePan(_ voice: Int32, _ pan: Float) {
        for i in 0..<voiceIds.count where voiceIds[i] == voice {
            voicePans[i] = max(-1, min(1, pan))
            return
        }
    }

    func stopVoice(_ voice: Int32) {
        for i in 0..<voiceIds.count where voiceIds[i] == voice {
            SDL_UnbindAudioStream(voiceStreams[i])
            SDL_DestroyAudioStream(voiceStreams[i])
            voiceStreams.remove(at: i)
            voiceLoops.remove(at: i)
            voiceIds.remove(at: i)
            voicePans.remove(at: i)
            return
        }
    }

    func setVoiceVolume(_ voice: Int32, _ volume: Float) {
        for i in 0..<voiceIds.count where voiceIds[i] == voice {
            _ = SDL_SetAudioStreamGain(voiceStreams[i], max(0, min(1, volume / 100)))
            return
        }
    }

    func reapVoices() {
        var i = 0
        while i < voiceStreams.count {
            let stream = voiceStreams[i]
            let queued = SDL_GetAudioStreamQueued(stream)
            let loopId = voiceLoops[i]
            if loopId > 0 {
                let li = Int(loopId)
                if queued < Int32(soundLens[li]) / 2 {
                    putData(stream, li, pan: voicePans[i])
                }
                i += 1
            } else if queued <= 0, SDL_GetAudioStreamAvailable(stream) <= 0 {
                SDL_UnbindAudioStream(stream)
                SDL_DestroyAudioStream(stream)
                voiceStreams.remove(at: i)
                voiceLoops.remove(at: i)
                voiceIds.remove(at: i)
                voicePans.remove(at: i)
            } else {
                i += 1
            }
        }
    }

    func storeGet(_ key: String) -> String? {
        for i in 0..<storeKeys.count where storeKeys[i] == key { return storeVals[i] }
        return nil
    }

    func storeSet(_ key: String, _ val: String) {
        for i in 0..<storeKeys.count where storeKeys[i] == key {
            storeVals[i] = val
            saveStore()
            return
        }
        storeKeys.append(key)
        storeVals.append(val)
        saveStore()
    }

    func saveStore() {
        var out = [UInt8]()
        for i in 0..<storeKeys.count {
            out.append(contentsOf: Array(storeKeys[i].utf8))
            out.append(9)
            out.append(contentsOf: Array(storeVals[i].utf8))
            out.append(10)
        }
        _ = storePath.withCString { path in
            out.withUnsafeBufferPointer { SDL_SaveFile(path, $0.baseAddress, $0.count) }
        }
    }

    func loadStore() {
        var size = 0
        let data = storePath.withCString { SDL_LoadFile($0, &size) }
        guard let data else { return }
        let bytes = UnsafeRawPointer(data).bindMemory(to: UInt8.self, capacity: size)
        var field = [UInt8]()
        var key = ""
        for i in 0..<size {
            let ch = bytes[i]
            if ch == 9 {
                field.append(0)
                key = field.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                field = []
            } else if ch == 10 {
                field.append(0)
                let val = field.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                field = []
                storeKeys.append(key)
                storeVals.append(val)
            } else {
                field.append(ch)
            }
        }
        SDL_free(data)
    }
}

func sfKey(_ scancode: UInt32) -> Int32 {
    switch scancode {
    case UInt32(SDL_SCANCODE_LEFT.rawValue): return 71
    case UInt32(SDL_SCANCODE_RIGHT.rawValue): return 72
    case UInt32(SDL_SCANCODE_UP.rawValue): return 73
    case UInt32(SDL_SCANCODE_DOWN.rawValue): return 74
    case UInt32(SDL_SCANCODE_SPACE.rawValue): return 57
    case UInt32(SDL_SCANCODE_ESCAPE.rawValue): return 36
    case UInt32(SDL_SCANCODE_RETURN.rawValue): return 58
    case UInt32(SDL_SCANCODE_BACKSPACE.rawValue): return 59
    case UInt32(SDL_SCANCODE_TAB.rawValue): return 60
    case UInt32(SDL_SCANCODE_A.rawValue)...UInt32(SDL_SCANCODE_Z.rawValue):
        return Int32(scancode - UInt32(SDL_SCANCODE_A.rawValue))
    case UInt32(SDL_SCANCODE_1.rawValue)...UInt32(SDL_SCANCODE_9.rawValue):
        return Int32(27 + scancode - UInt32(SDL_SCANCODE_1.rawValue))
    case UInt32(SDL_SCANCODE_0.rawValue): return 26
    default: return -1
    }
}

func toLogical(_ window: OpaquePointer?, _ x: Float, _ y: Float) -> (Int32, Int32) {
    var w: Int32 = 0
    var h: Int32 = 0
    _ = SDL_GetWindowSize(window, &w, &h)
    let sc = min(Float(w) / LOGICAL_W, Float(h) / LOGICAL_H)
    let ox = (Float(w) - LOGICAL_W * sc) / 2
    let oy = (Float(h) - LOGICAL_H * sc) / 2
    return (Int32((x - ox) / sc), Int32((y - oy) / sc))
}

// MARK: - host lifecycle (called by main)

func kitHostInit(appName: String = "KitGame") {
    guard SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO) else { fatalError("SDL_Init failed") }
    let k = Kit.shared
    let ok = "AsteroidZ - Embedded Swift DIRECT native (no wasm)".withCString {
        SDL_CreateWindowAndRenderer($0, 1920, 1080,
                                    windowResizable | windowHighPixelDensity,
                                    &k.window, &k.renderer)
    }
    guard ok else { fatalError("window failed") }
    _ = SDL_SetRenderVSync(k.renderer, 1)
    _ = SDL_SetRenderDrawBlendMode(k.renderer, SDL_BLENDMODE_BLEND)
    if let pref = ("SuperBox64".withCString { org in appName.withCString { SDL_GetPrefPath(org, $0) } }) {
        k.storePath = String(cString: pref) + "store.tsv"
        SDL_free(pref)
    }
    k.loadStore()
}

// Pump SDL into the ABI event queue; false = quit requested.
func kitHostPump() -> Bool {
    let k = Kit.shared
    var alive = true
    var e = SDL_Event()
    while SDL_PollEvent(&e) {
        if e.type == SDL_EVENT_QUIT.rawValue {
            alive = false
        } else if e.type == SDL_EVENT_KEY_DOWN.rawValue, e.key.scancode == SDL_SCANCODE_F, !e.key.`repeat` {
            k.fullscreen = !k.fullscreen
            _ = SDL_SetWindowFullscreen(k.window, k.fullscreen)
        } else if e.type == SDL_EVENT_KEY_DOWN.rawValue || e.type == SDL_EVENT_KEY_UP.rawValue {
            let sf = sfKey(e.key.scancode.rawValue)
            if sf >= 0, !e.key.`repeat` {
                let t: Int32 = e.type == SDL_EVENT_KEY_DOWN.rawValue ? 5 : 6
                let shift: Int32 = (UInt32(e.key.mod) & SDL_KMOD_SHIFT) != 0 ? 1 : 0
                k.events.append((t, sf, shift, 0, 0))
            }
        } else if e.type == SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue || e.type == SDL_EVENT_MOUSE_BUTTON_UP.rawValue {
            let t: Int32 = e.type == SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue ? 9 : 10
            let (lx, ly) = toLogical(k.window, e.button.x, e.button.y)
            k.events.append((t, 0, lx, ly, 0))
        } else if e.type == SDL_EVENT_MOUSE_MOTION.rawValue {
            let (lx, ly) = toLogical(k.window, e.motion.x, e.motion.y)
            k.events.append((11, lx, ly, 0, 0))
        }
    }
    return alive
}

func kitHostPresent() {
    Kit.shared.reapVoices()
    _ = SDL_RenderPresent(Kit.shared.renderer)
}

// MARK: - the KitABI env surface, linked directly (no wasm in between)

@_cdecl("js_log")
func js_log(_ p: UnsafePointer<CChar>?, _ len: Int32) {
    print(Kit.shared.cString(p, len))
}

@_cdecl("gfx_clear")
func gfx_clear(_ rgba: UInt32) {
    let k = Kit.shared
    var pw: Int32 = 0
    var ph: Int32 = 0
    _ = SDL_GetRenderOutputSize(k.renderer, &pw, &ph)
    let sc = min(Float(pw) / LOGICAL_W, Float(ph) / LOGICAL_H)
    k.mat = Mat(a: sc, b: 0, c: 0, d: sc,
                e: (Float(pw) - LOGICAL_W * sc) / 2,
                f: (Float(ph) - LOGICAL_H * sc) / 2)
    k.stack = []
    k.alpha = 1
        k.additive = false
    let c = k.fcolor(rgba)
    _ = SDL_SetRenderDrawColorFloat(k.renderer, c.r, c.g, c.b, 1)
    _ = SDL_RenderClear(k.renderer)
}

@_cdecl("gfx_save")
func gfx_save() { Kit.shared.stack.append(Kit.shared.mat) }

@_cdecl("gfx_restore")
func gfx_restore() { if let m = Kit.shared.stack.popLast() { Kit.shared.mat = m } }

@_cdecl("gfx_translate")
func gfx_translate(_ x: Float, _ y: Float) {
    Kit.shared.mat.mul(Mat(a: 1, b: 0, c: 0, d: 1, e: x, f: y))
}

@_cdecl("gfx_rotate")
func gfx_rotate(_ degrees: Float) {
    let r = degrees * Float.pi / 180
    Kit.shared.mat.mul(Mat(a: SDL_cosf(r), b: SDL_sinf(r), c: -SDL_sinf(r), d: SDL_cosf(r), e: 0, f: 0))
}

@_cdecl("gfx_scale")
func gfx_scale(_ sx: Float, _ sy: Float) {
    Kit.shared.mat.mul(Mat(a: sx, b: 0, c: 0, d: sy, e: 0, f: 0))
}

@_cdecl("gfx_set_alpha")
func gfx_set_alpha(_ a: Float) { Kit.shared.alpha = a }

@_cdecl("gfx_set_blend")
func gfx_set_blend(_ mode: Int32) { Kit.shared.additive = mode == 1 }

@_cdecl("gfx_stroke_poly")
func gfx_stroke_poly(_ xy: UnsafePointer<Float>?, _ n: Int32, _ closed: Int32, _ t: Float, _ rgba: UInt32) {
    guard let xy, n >= 2 else { return }
    let k = Kit.shared
    var pts = [SDL_FPoint]()
    pts.reserveCapacity(Int(n))
    for i in 0..<Int(n) { pts.append(k.mat.apply(xy[i * 2], xy[i * 2 + 1])) }
    k.strokePoly(pts, closed: closed != 0, thickness: t, rgba: rgba)
}

@_cdecl("gfx_fill_poly")
func gfx_fill_poly(_ xy: UnsafePointer<Float>?, _ n: Int32, _ rgba: UInt32) {
    guard let xy, n >= 3 else { return }
    let k = Kit.shared
    var pts = [SDL_FPoint]()
    pts.reserveCapacity(Int(n))
    for i in 0..<Int(n) { pts.append(k.mat.apply(xy[i * 2], xy[i * 2 + 1])) }
    k.fillPoly(pts, rgba: rgba)
}

@_cdecl("gfx_fill_circle")
func gfx_fill_circle(_ cx: Float, _ cy: Float, _ r: Float, _ rgba: UInt32) {
    let k = Kit.shared
    k.fillPoly(k.circlePts(cx, cy, r), rgba: rgba)
}

@_cdecl("gfx_stroke_circle")
func gfx_stroke_circle(_ cx: Float, _ cy: Float, _ r: Float, _ t: Float, _ rgba: UInt32) {
    let k = Kit.shared
    k.strokePoly(k.circlePts(cx, cy, r), closed: true, thickness: t, rgba: rgba)
}

@_cdecl("gfx_fill_rect")
func gfx_fill_rect(_ x: Float, _ y: Float, _ w: Float, _ h: Float, _ rgba: UInt32) {
    let k = Kit.shared
    k.fillPoly([k.mat.apply(x, y), k.mat.apply(x + w, y),
                k.mat.apply(x + w, y + h), k.mat.apply(x, y + h)], rgba: rgba)
}

@_cdecl("gfx_stroke_rect")
func gfx_stroke_rect(_ x: Float, _ y: Float, _ w: Float, _ h: Float, _ t: Float, _ rgba: UInt32) {
    let k = Kit.shared
    k.strokePoly([k.mat.apply(x, y), k.mat.apply(x + w, y),
                  k.mat.apply(x + w, y + h), k.mat.apply(x, y + h)],
                 closed: true, thickness: t, rgba: rgba)
}

@_cdecl("evt_poll")
func evt_poll(_ type: UnsafeMutablePointer<Int32>?, _ a: UnsafeMutablePointer<Int32>?,
              _ b: UnsafeMutablePointer<Int32>?, _ c: UnsafeMutablePointer<Int32>?,
              _ d: UnsafeMutablePointer<Int32>?) -> Int32 {
    let k = Kit.shared
    if k.events.isEmpty { return 0 }
    let e = k.events.removeFirst()
    type?.pointee = e.0
    a?.pointee = e.1
    b?.pointee = e.2
    c?.pointee = e.3
    d?.pointee = e.4
    return 1
}

@_cdecl("snd_by_name")
func snd_by_name(_ name: UnsafePointer<CChar>?, _ len: Int32) -> Int32 {
    Kit.shared.loadSound(Kit.shared.cString(name, len))
}

@_cdecl("snd_play")
func snd_play(_ buffer: Int32, _ volume: Float, _ loop: Int32) -> Int32 {
    Kit.shared.play(buffer, volume: volume, loop: loop != 0)
}

@_cdecl("snd_stop")
func snd_stop(_ voice: Int32) {
    Kit.shared.stopVoice(voice)
}

@_cdecl("snd_set_volume")
func snd_set_volume(_ voice: Int32, _ volume: Float) {
    Kit.shared.setVoiceVolume(voice, volume)
}

@_cdecl("snd_set_pan")
func snd_set_pan(_ voice: Int32, _ pan: Float) {
    Kit.shared.setVoicePan(voice, pan)
}

@_cdecl("store_get")
func store_get(_ key: UnsafePointer<CChar>?, _ klen: Int32,
               _ buf: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    let k = Kit.shared
    guard let v = k.storeGet(k.cString(key, klen)) else { return -1 }
    let bytes = Array(v.utf8)
    let n = min(bytes.count, Int(cap))
    if let buf {
        for i in 0..<n { buf[i] = CChar(bitPattern: bytes[i]) }
    }
    return Int32(n)
}

@_cdecl("store_set")
func store_set(_ key: UnsafePointer<CChar>?, _ klen: Int32,
               _ val: UnsafePointer<CChar>?, _ vlen: Int32) {
    let k = Kit.shared
    k.storeSet(k.cString(key, klen), k.cString(val, vlen))
}

@_cdecl("gp_connected")
func gp_connected(_ pad: Int32) -> Int32 { 0 }
