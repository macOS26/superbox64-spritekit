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

@_silgen_name("kit_png_decode")
func kit_png_decode(_ bytes: UnsafePointer<UInt8>?, _ len: Int32, _ w: UnsafeMutablePointer<Int32>?, _ h: UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<UInt8>?

@_silgen_name("kit_stb_free")
func kit_stb_free(_ p: UnsafeMutableRawPointer?)

@_silgen_name("kit_font_init")
func kit_font_init(_ ttf: UnsafePointer<UInt8>?, _ len: Int32) -> UnsafeMutableRawPointer?

@_silgen_name("kit_font_scale_for_px")
func kit_font_scale_for_px(_ font: UnsafeMutableRawPointer?, _ px: Float) -> Float

@_silgen_name("kit_font_vmetrics")
func kit_font_vmetrics(_ font: UnsafeMutableRawPointer?, _ ascent: UnsafeMutablePointer<Int32>?, _ descent: UnsafeMutablePointer<Int32>?, _ lineGap: UnsafeMutablePointer<Int32>?)

@_silgen_name("kit_font_hmetrics")
func kit_font_hmetrics(_ font: UnsafeMutableRawPointer?, _ codepoint: Int32, _ advance: UnsafeMutablePointer<Int32>?, _ lsb: UnsafeMutablePointer<Int32>?)

@_silgen_name("kit_font_kern")
func kit_font_kern(_ font: UnsafeMutableRawPointer?, _ cp1: Int32, _ cp2: Int32) -> Int32

@_silgen_name("kit_font_glyph_bitmap")
func kit_font_glyph_bitmap(_ font: UnsafeMutableRawPointer?, _ scale: Float, _ codepoint: Int32, _ w: UnsafeMutablePointer<Int32>?, _ h: UnsafeMutablePointer<Int32>?, _ xoff: UnsafeMutablePointer<Int32>?, _ yoff: UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<UInt8>?

@_silgen_name("kit_font_glyph_index")
func kit_font_glyph_index(_ font: UnsafeMutableRawPointer?, _ codepoint: Int32) -> Int32

@_silgen_name("kit_emoji_init")
func kit_emoji_init(_ ttf: UnsafePointer<UInt8>?, _ len: Int32) -> UnsafeMutableRawPointer?

@_silgen_name("kit_emoji_glyph_png")
func kit_emoji_glyph_png(_ handle: UnsafeMutableRawPointer?, _ codepoint: Int32, _ pngLen: UnsafeMutablePointer<UInt32>?, _ ppem: UnsafeMutablePointer<Int32>?, _ bearingX: UnsafeMutablePointer<Int32>?, _ bearingY: UnsafeMutablePointer<Int32>?, _ advance: UnsafeMutablePointer<Int32>?) -> UnsafePointer<UInt8>?

final class Kit {
    static let shared = Kit()
    var window: OpaquePointer? = nil
    var renderer: OpaquePointer? = nil
    var mat = Mat()
    var stack: [Mat] = []
    var alpha: Float = 1
    var events: [(Int32, Int32, Int32, Int32, Int32)] = []
    var evtMutex: OpaquePointer? = nil

    func pushEvent(_ e: (Int32, Int32, Int32, Int32, Int32)) {
        if evtMutex == nil { evtMutex = SDL_CreateMutex() }
        SDL_LockMutex(evtMutex)
        events.append(e)
        SDL_UnlockMutex(evtMutex)
    }

    func popEvent() -> (Int32, Int32, Int32, Int32, Int32)? {
        if evtMutex == nil { evtMutex = SDL_CreateMutex() }
        SDL_LockMutex(evtMutex)
        let e = events.isEmpty ? nil : events.removeFirst()
        SDL_UnlockMutex(evtMutex)
        return e
    }
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

    // host-pluggable asset source (WasmCart serves cart zip entries here);
    // falls back to baked-in kit_asset_data, then plain files on disk
    var assetProvider: ((String) -> [UInt8]?)? = nil
    var baseScale: Float = 1
    var textBaseline: Int32 = 2

    // the game's fixed logical canvas, the same per-game value the web host
    // page passes as WASMWEB.logicalWidth/Height; carts carry it in their
    // manifest.json and the host sets it at insert
    var logicalW: Float = LOGICAL_W
    var logicalH: Float = LOGICAL_H

    // persistent screen target, the SDL stand-in for the web canvas: frames
    // that repaint nothing (static title screens) keep showing the last
    // composite instead of flipping to an undefined backbuffer
    var screenTex: UnsafeMutablePointer<SDL_Texture>? = nil
    var screenW: Int32 = 0
    var screenH: Int32 = 0

    func ensureScreenTarget() {
        var pw: Int32 = 0
        var ph: Int32 = 0
        _ = SDL_GetWindowSizeInPixels(window, &pw, &ph)
        if screenTex == nil || pw != screenW || ph != screenH {
            if let old = screenTex { SDL_DestroyTexture(old) }
            screenTex = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_TARGET, pw, ph)
            screenW = pw
            screenH = ph
        }
        _ = SDL_SetRenderTarget(renderer, screenTex)
    }

    struct ImgRec {
        var tex: UnsafeMutablePointer<SDL_Texture>?
        var w: Int32
        var h: Int32
    }
    var images: [ImgRec?] = [nil]
    var freeImageSlots: [Int] = []
    var imageNames: [String: Int32] = [:]

    var fontInfos: [UnsafeMutableRawPointer?] = [nil]
    var fontNames: [String: Int32] = [:]
    var defaultFont: Int32 = -1

    var emojiFont: UnsafeMutableRawPointer? = nil

    struct EmojiGlyph {
        var tex: UnsafeMutablePointer<SDL_Texture>?
        var w: Int32
        var h: Int32
        var ppem: Int32
        var bearingX: Int32
        var bearingY: Int32
        var advance: Int32
    }
    var emojiCache: [Int: EmojiGlyph] = [:]

    func setEmojiFont(_ ttf: UnsafePointer<UInt8>?, _ len: Int) {
        emojiFont = kit_emoji_init(ttf, Int32(len))
    }

    func emojiGlyph(_ cp: Int32) -> EmojiGlyph? {
        guard let emojiFont else { return nil }
        if let g = emojiCache[Int(cp)] { return g }
        var pngLen: UInt32 = 0
        var ppem: Int32 = 0
        var bearingX: Int32 = 0
        var bearingY: Int32 = 0
        var advance: Int32 = 0
        guard let png = kit_emoji_glyph_png(emojiFont, cp, &pngLen, &ppem, &bearingX, &bearingY, &advance) else { return nil }
        var w: Int32 = 0
        var h: Int32 = 0
        guard let pixels = kit_png_decode(png, Int32(pngLen), &w, &h) else { return nil }
        let tex = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STATIC, w, h)
        var rect = SDL_Rect(x: 0, y: 0, w: w, h: h)
        _ = SDL_UpdateTexture(tex, &rect, pixels, w * 4)
        kit_stb_free(pixels)
        _ = SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND)
        let g = EmojiGlyph(tex: tex, w: w, h: h, ppem: ppem, bearingX: bearingX, bearingY: bearingY, advance: advance)
        emojiCache[Int(cp)] = g
        return g
    }

    struct Glyph {
        var tex: UnsafeMutablePointer<SDL_Texture>?
        var w: Int32
        var h: Int32
        var xoff: Int32
        var yoff: Int32
    }
    var glyphCache: [Int: Glyph] = [:]

    struct OffTarget {
        var tex: UnsafeMutablePointer<SDL_Texture>?
        var w: Int32
        var h: Int32
        var savedMat: Mat
        var savedStack: [Mat]
        var savedAlpha: Float
        var prevTarget: UnsafeMutablePointer<SDL_Texture>?
    }
    var targets: [OffTarget?] = []

    var engVolumes: [Int32: Float] = [:]
    var engPlayers: [Int32: (sound: Int32, loops: Int32, voice: Int32)] = [:]
    var nextEngId: Int32 = 1

    func assetBytes(_ name: String) -> [UInt8]? {
        if let provider = assetProvider {
            if let d = provider(name) { return d }
        }
        var memLen: UInt32 = 0
        if let mem = name.withCString({ kit_asset_data($0, &memLen) }), memLen > 0 {
            var out = [UInt8]()
            out.reserveCapacity(Int(memLen))
            for i in 0..<Int(memLen) { out.append(mem[i]) }
            return out
        }
        for path in [name, "assets/" + name] {
            var size = 0
            if let data = path.withCString({ SDL_LoadFile($0, &size) }), size > 0 {
                let bytes = UnsafeRawPointer(data).bindMemory(to: UInt8.self, capacity: size)
                var out = [UInt8]()
                out.reserveCapacity(size)
                for i in 0..<size { out.append(bytes[i]) }
                SDL_free(data)
                return out
            }
        }
        return nil
    }

    func baseName(_ name: String) -> String {
        var bytes = Array(name.utf8)
        var lastSlash = -1
        for i in 0..<bytes.count where bytes[i] == 47 { lastSlash = i }
        if lastSlash >= 0 { bytes.removeFirst(lastSlash + 1) }
        bytes.append(0)
        return bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    func registerImage(_ rec: ImgRec) -> Int32 {
        if let slot = freeImageSlots.popLast() {
            images[slot] = rec
            return Int32(slot)
        }
        images.append(rec)
        return Int32(images.count - 1)
    }

    func imageByName(_ name: String) -> Int32 {
        if let id = imageNames[name] { return id }
        var data = assetBytes(name)
        if data == nil { data = assetBytes("images/" + name) }
        if data == nil { data = assetBytes("images/" + name + ".png") }
        if data == nil { data = assetBytes(baseName(name)) }
        guard let data else { return 0 }
        var w: Int32 = 0
        var h: Int32 = 0
        guard let pixels = data.withUnsafeBufferPointer({ kit_png_decode($0.baseAddress, Int32(data.count), &w, &h) }) else { return 0 }
        let tex = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STATIC, w, h)
        var rect = SDL_Rect(x: 0, y: 0, w: w, h: h)
        _ = SDL_UpdateTexture(tex, &rect, pixels, w * 4)
        kit_stb_free(pixels)
        _ = SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND)
        let id = registerImage(ImgRec(tex: tex, w: w, h: h))
        imageNames[name] = id
        return id
    }

    func fontByName(_ name: String) -> Int32 {
        if let id = fontNames[name] { return id }
        var data = assetBytes(name)
        if data == nil { data = assetBytes("fonts/" + name) }
        if data == nil { data = assetBytes("fonts/" + name + ".ttf") }
        if data == nil { data = assetBytes(baseName(name)) }
        guard let data else { return 0 }
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
        for i in 0..<data.count { buf[i] = data[i] }
        guard let info = kit_font_init(buf, Int32(data.count)) else {
            buf.deallocate()
            return 0
        }
        let id = Int32(fontInfos.count)
        fontInfos.append(info)
        fontNames[name] = id
        return id
    }

    func resolveFont(_ font: Int32) -> UnsafeMutableRawPointer? {
        if font > 0, Int(font) < fontInfos.count { return fontInfos[Int(font)] }
        if defaultFont < 0 {
            defaultFont = 0
            for candidate in ["JetBrainsMono-Bold.ttf", "Menlo-Regular.ttf", "Menlo-Bold.ttf"] {
                let id = fontByName(candidate)
                if id > 0 {
                    defaultFont = id
                    break
                }
            }
            if defaultFont == 0, fontInfos.count > 1 { defaultFont = 1 }
        }
        if defaultFont > 0, Int(defaultFont) < fontInfos.count { return fontInfos[Int(defaultFont)] }
        return nil
    }

    func decodeUTF8(_ p: UnsafePointer<CChar>?, _ len: Int32) -> [Int32] {
        var cps = [Int32]()
        guard let p else { return cps }
        var i = 0
        let n = Int(len)
        while i < n {
            let b0 = UInt32(UInt8(bitPattern: p[i]))
            var cp: UInt32 = 0
            var extra = 0
            if b0 < 0x80 { cp = b0 } else if b0 < 0xE0 { cp = b0 & 0x1F; extra = 1 } else if b0 < 0xF0 { cp = b0 & 0x0F; extra = 2 } else { cp = b0 & 0x07; extra = 3 }
            if i + extra >= n { break }
            for j in 1...max(1, extra) where extra > 0 {
                cp = (cp << 6) | (UInt32(UInt8(bitPattern: p[i + j])) & 0x3F)
            }
            cps.append(Int32(bitPattern: cp))
            i += 1 + extra
        }
        return cps
    }

    func glyph(_ font: Int32, _ info: UnsafeMutableRawPointer, _ cp: Int32, _ sizePx: Int32) -> Glyph? {
        let key = (Int(font) << 44) | (Int(cp) << 12) | Int(sizePx & 0xFFF)
        if let g = glyphCache[key] { return g }
        let scale = kit_font_scale_for_px(info, Float(sizePx))
        var w: Int32 = 0
        var h: Int32 = 0
        var xoff: Int32 = 0
        var yoff: Int32 = 0
        guard let bitmap = kit_font_glyph_bitmap(info, scale, cp, &w, &h, &xoff, &yoff) else {
            let g = Glyph(tex: nil, w: 0, h: 0, xoff: 0, yoff: 0)
            glyphCache[key] = g
            return g
        }
        var g = Glyph(tex: nil, w: w, h: h, xoff: xoff, yoff: yoff)
        if w > 0, h > 0 {
            var rgba = [UInt8](repeating: 255, count: Int(w * h * 4))
            for i in 0..<Int(w * h) { rgba[i * 4 + 3] = bitmap[i] }
            let tex = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STATIC, w, h)
            var rect = SDL_Rect(x: 0, y: 0, w: w, h: h)
            _ = rgba.withUnsafeBufferPointer { SDL_UpdateTexture(tex, &rect, $0.baseAddress, w * 4) }
            _ = SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND)
            g.tex = tex
        }
        kit_stb_free(bitmap)
        glyphCache[key] = g
        return g
    }

    func drawTexturedQuad(_ tex: UnsafeMutablePointer<SDL_Texture>?, _ dx: Float, _ dy: Float, _ dw: Float, _ dh: Float,
                          _ u0: Float, _ v0: Float, _ u1: Float, _ v1: Float, _ color: SDL_FColor) {
        guard let tex else { return }
        _ = SDL_SetTextureBlendMode(tex, additive ? SDL_BLENDMODE_ADD : SDL_BLENDMODE_BLEND)
        let p0 = mat.apply(dx, dy)
        let p1 = mat.apply(dx + dw, dy)
        let p2 = mat.apply(dx + dw, dy + dh)
        let p3 = mat.apply(dx, dy + dh)
        let verts = [
            SDL_Vertex(position: p0, color: color, tex_coord: SDL_FPoint(x: u0, y: v0)),
            SDL_Vertex(position: p1, color: color, tex_coord: SDL_FPoint(x: u1, y: v0)),
            SDL_Vertex(position: p2, color: color, tex_coord: SDL_FPoint(x: u1, y: v1)),
            SDL_Vertex(position: p3, color: color, tex_coord: SDL_FPoint(x: u0, y: v1)),
        ]
        let idx: [Int32] = [0, 1, 2, 0, 2, 3]
        SDL_RenderGeometry(renderer, tex, verts, 4, idx, 6)
    }

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

    func stopAllVoices() {
        for stream in voiceStreams {
            SDL_UnbindAudioStream(stream)
            SDL_DestroyAudioStream(stream)
        }
        voiceStreams.removeAll()
        voiceLoops.removeAll()
        voiceIds.removeAll()
        voicePans.removeAll()
        soundSpecs = [SDL_AudioSpec()]
        soundBufs = [nil]
        soundLens = [0]
        soundNames = [:]
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
    let k = Kit.shared
    var w: Int32 = 0
    var h: Int32 = 0
    _ = SDL_GetWindowSize(window, &w, &h)
    let sc = min(Float(w) / k.logicalW, Float(h) / k.logicalH)
    let ox = (Float(w) - k.logicalW * sc) / 2
    let oy = (Float(h) - k.logicalH * sc) / 2
    return (Int32((x - ox) / sc), Int32((y - oy) / sc))
}

// MARK: - host lifecycle (called by main)

func kitHostInit(appName: String = "KitGame") {
    guard SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO) else { fatalError("SDL_Init failed") }
    let k = Kit.shared
    let ok = appName.withCString {
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
// A console host (WasmCart) reserves ESC for eject; when set, ESC never
// reaches the game and lands in kitEscapePressed instead.
nonisolated(unsafe) var kitEscapeReserved = false
nonisolated(unsafe) var kitEscapePressed = false
nonisolated(unsafe) var kitDroppedFile: String? = nil

func kitHostPump() -> Bool {
    let k = Kit.shared
    var alive = true
    var e = SDL_Event()
    while SDL_PollEvent(&e) {
        if e.type == SDL_EVENT_QUIT.rawValue {
            alive = false
        } else if e.type == SDL_EVENT_DROP_FILE.rawValue {
            if let dropped = e.drop.data {
                kitDroppedFile = String(cString: dropped)
            }
        } else if e.type == SDL_EVENT_KEY_DOWN.rawValue, e.key.scancode == SDL_SCANCODE_F, !e.key.`repeat` {
            k.fullscreen = !k.fullscreen
            _ = SDL_SetWindowFullscreen(k.window, k.fullscreen)
        } else if kitEscapeReserved, e.type == SDL_EVENT_KEY_DOWN.rawValue,
                  e.key.scancode == SDL_SCANCODE_ESCAPE, !e.key.`repeat` {
            kitEscapePressed = true
        } else if e.type == SDL_EVENT_KEY_DOWN.rawValue || e.type == SDL_EVENT_KEY_UP.rawValue {
            let sf = sfKey(e.key.scancode.rawValue)
            if sf >= 0, !e.key.`repeat` {
                let t: Int32 = e.type == SDL_EVENT_KEY_DOWN.rawValue ? 5 : 6
                let shift: Int32 = (UInt32(e.key.mod) & SDL_KMOD_SHIFT) != 0 ? 1 : 0
                k.pushEvent((t, sf, shift, 0, 0))
            }
        } else if e.type == SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue || e.type == SDL_EVENT_MOUSE_BUTTON_UP.rawValue {
            let t: Int32 = e.type == SDL_EVENT_MOUSE_BUTTON_DOWN.rawValue ? 9 : 10
            let (lx, ly) = toLogical(k.window, e.button.x, e.button.y)
            k.pushEvent((t, 0, lx, ly, 0))
        } else if e.type == SDL_EVENT_MOUSE_MOTION.rawValue {
            let (lx, ly) = toLogical(k.window, e.motion.x, e.motion.y)
            k.pushEvent((11, lx, ly, 0, 0))
        }
    }
    return alive
}

func kitHostPresent() {
    let k = Kit.shared
    k.reapVoices()
    if let screen = k.screenTex {
        _ = SDL_SetRenderTarget(k.renderer, nil)
        _ = SDL_SetTextureBlendMode(screen, SDL_BLENDMODE_NONE)
        _ = SDL_RenderTexture(k.renderer, screen, nil, nil)
        _ = SDL_RenderPresent(k.renderer)
        _ = SDL_SetRenderTarget(k.renderer, screen)
    } else {
        _ = SDL_RenderPresent(k.renderer)
    }
}

// MARK: - the KitABI env surface, linked directly (no wasm in between)

@_cdecl("js_log")
func js_log(_ p: UnsafePointer<CChar>?, _ len: Int32) {
    print(Kit.shared.cString(p, len))
}

@_cdecl("gfx_clear")
func gfx_clear(_ rgba: UInt32) {
    let k = Kit.shared
    if k.targets.contains(where: { $0 != nil }) {
        let c = k.fcolor(rgba)
        _ = SDL_SetRenderDrawColorFloat(k.renderer, c.r, c.g, c.b, 1)
        _ = SDL_RenderClear(k.renderer)
        return
    }
    k.ensureScreenTarget()
    let pw = k.screenW
    let ph = k.screenH
    let sc = min(Float(pw) / k.logicalW, Float(ph) / k.logicalH)
    k.baseScale = sc
    k.mat = Mat(a: sc, b: 0, c: 0, d: sc,
                e: (Float(pw) - k.logicalW * sc) / 2,
                f: (Float(ph) - k.logicalH * sc) / 2)
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
    guard let e = k.popEvent() else { return 0 }
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

// MARK: - images, offscreen targets, text (the texture half of the ABI)

@_cdecl("img_by_name")
func img_by_name(_ name: UnsafePointer<CChar>?, _ len: Int32) -> Int32 {
    let k = Kit.shared
    return k.imageByName(k.cString(name, len))
}

@_cdecl("img_width")
func img_width(_ img: Int32) -> Int32 {
    let k = Kit.shared
    guard img > 0, Int(img) < k.images.count, let rec = k.images[Int(img)] else { return 0 }
    return rec.w
}

@_cdecl("img_height")
func img_height(_ img: Int32) -> Int32 {
    let k = Kit.shared
    guard img > 0, Int(img) < k.images.count, let rec = k.images[Int(img)] else { return 0 }
    return rec.h
}

@_cdecl("gfx_draw_image")
func gfx_draw_image(_ img: Int32, _ sx: Float, _ sy: Float, _ sw: Float, _ sh: Float,
                    _ dx: Float, _ dy: Float, _ dw: Float, _ dh: Float, _ rgba: UInt32) {
    let k = Kit.shared
    guard img > 0, Int(img) < k.images.count, let rec = k.images[Int(img)], rec.tex != nil else { return }
    let a = Float(rgba & 0xFF) / 255 * k.alpha
    let color = SDL_FColor(r: 1, g: 1, b: 1, a: a)
    var u0: Float = 0
    var v0: Float = 0
    var u1: Float = 1
    var v1: Float = 1
    if sw >= 0, sh >= 0, rec.w > 0, rec.h > 0 {
        u0 = sx / Float(rec.w)
        v0 = sy / Float(rec.h)
        u1 = (sx + sw) / Float(rec.w)
        v1 = (sy + sh) / Float(rec.h)
    }
    k.drawTexturedQuad(rec.tex, dx, dy, dw, dh, u0, v0, u1, v1, color)
}

@_cdecl("gfx_free_image")
func gfx_free_image(_ img: Int32) {
    let k = Kit.shared
    guard img > 0, Int(img) < k.images.count, let rec = k.images[Int(img)] else { return }
    if let tex = rec.tex { SDL_DestroyTexture(tex) }
    k.images[Int(img)] = nil
    k.freeImageSlots.append(Int(img))
}

@_cdecl("gfx_upload_pixels")
func gfx_upload_pixels(_ img: Int32, _ w: Int32, _ h: Int32, _ rgba: UnsafePointer<UInt8>?, _ len: Int32) -> Int32 {
    let k = Kit.shared
    guard let rgba, w > 0, h > 0, len >= w * h * 4 else { return img }
    let tex = SDL_CreateTexture(k.renderer, SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_STATIC, w, h)
    var rect = SDL_Rect(x: 0, y: 0, w: w, h: h)
    _ = SDL_UpdateTexture(tex, &rect, rgba, w * 4)
    _ = SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND)
    if img > 0, Int(img) < k.images.count {
        if let old = k.images[Int(img)]?.tex { SDL_DestroyTexture(old) }
        k.images[Int(img)] = Kit.ImgRec(tex: tex, w: w, h: h)
        return img
    }
    return k.registerImage(Kit.ImgRec(tex: tex, w: w, h: h))
}

@_cdecl("gfx_offscreen_begin")
func gfx_offscreen_begin(_ w: Int32, _ h: Int32) -> Int32 {
    let k = Kit.shared
    let dpr = max(1, k.baseScale)
    let tw = Int32(Float(w) * dpr + 0.5)
    let th = Int32(Float(h) * dpr + 0.5)
    guard tw > 0, th > 0,
          let tex = SDL_CreateTexture(k.renderer, SDL_PIXELFORMAT_ABGR8888, SDL_TEXTUREACCESS_TARGET, tw, th) else { return 0 }
    _ = SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND)
    let prev = SDL_GetRenderTarget(k.renderer)
    _ = SDL_SetRenderTarget(k.renderer, tex)
    _ = SDL_SetRenderDrawColorFloat(k.renderer, 0, 0, 0, 0)
    _ = SDL_RenderClear(k.renderer)
    k.targets.append(Kit.OffTarget(tex: tex, w: tw, h: th,
                                   savedMat: k.mat, savedStack: k.stack, savedAlpha: k.alpha,
                                   prevTarget: prev))
    k.mat = Mat(a: dpr, b: 0, c: 0, d: dpr, e: 0, f: 0)
    k.stack = []
    k.alpha = 1
    return Int32(k.targets.count)
}

@_cdecl("gfx_offscreen_end_to_image")
func gfx_offscreen_end_to_image(_ handle: Int32) -> Int32 {
    let k = Kit.shared
    guard handle >= 1, Int(handle) <= k.targets.count, let t = k.targets[Int(handle) - 1] else { return 0 }
    _ = SDL_SetRenderTarget(k.renderer, t.prevTarget)
    k.mat = t.savedMat
    k.stack = t.savedStack
    k.alpha = t.savedAlpha
    k.targets[Int(handle) - 1] = nil
    while let last = k.targets.last, last == nil { k.targets.removeLast() }
    return k.registerImage(Kit.ImgRec(tex: t.tex, w: t.w, h: t.h))
}

@_cdecl("gfx_offscreen_end_discard")
func gfx_offscreen_end_discard(_ handle: Int32) {
    let k = Kit.shared
    guard handle >= 1, Int(handle) <= k.targets.count, let t = k.targets[Int(handle) - 1] else { return }
    _ = SDL_SetRenderTarget(k.renderer, t.prevTarget)
    k.mat = t.savedMat
    k.stack = t.savedStack
    k.alpha = t.savedAlpha
    if let tex = t.tex { SDL_DestroyTexture(tex) }
    k.targets[Int(handle) - 1] = nil
    while let last = k.targets.last, last == nil { k.targets.removeLast() }
}

@_cdecl("font_by_name")
func font_by_name(_ name: UnsafePointer<CChar>?, _ len: Int32) -> Int32 {
    let k = Kit.shared
    return k.fontByName(k.cString(name, len))
}

@_cdecl("txt_width")
func txt_width(_ font: Int32, _ utf8: UnsafePointer<CChar>?, _ len: Int32, _ sizePx: Int32, _ spacing: Float) -> Int32 {
    let k = Kit.shared
    guard let info = k.resolveFont(font) else { return 0 }
    let cps = k.decodeUTF8(utf8, len)
    if cps.isEmpty { return 0 }
    let scale = kit_font_scale_for_px(info, Float(sizePx))
    var w: Float = 0
    for i in 0..<cps.count {
        let cp = cps[i]
        if cp == 0xFE0F || cp == 0x200D { continue }
        if kit_font_glyph_index(info, cp) == 0, let eg = k.emojiGlyph(cp) {
            w += Float(eg.advance) * Float(sizePx) / Float(eg.ppem)
        } else {
            var advance: Int32 = 0
            var lsb: Int32 = 0
            kit_font_hmetrics(info, cp, &advance, &lsb)
            w += Float(advance) * scale
            if i + 1 < cps.count {
                w += Float(kit_font_kern(info, cp, cps[i + 1])) * scale
            }
        }
    }
    w += spacing * Float(cps.count - 1)
    return Int32(SDL_ceilf(w))
}

@_cdecl("gfx_set_text_baseline")
func gfx_set_text_baseline(_ mode: Int32) {
    Kit.shared.textBaseline = mode
}

@_cdecl("gfx_draw_text")
func gfx_draw_text(_ font: Int32, _ utf8: UnsafePointer<CChar>?, _ len: Int32,
                   _ x: Float, _ y: Float, _ sizePx: Int32, _ rgba: UInt32, _ spacing: Float) {
    let k = Kit.shared
    guard let info = k.resolveFont(font) else { return }
    let cps = k.decodeUTF8(utf8, len)
    if cps.isEmpty { return }
    let scale = kit_font_scale_for_px(info, Float(sizePx))
    var ascent: Int32 = 0
    var descent: Int32 = 0
    var lineGap: Int32 = 0
    kit_font_vmetrics(info, &ascent, &descent, &lineGap)
    let ascentPx = Float(ascent) * scale
    let descentPx = Float(descent) * scale
    var baselineY = y
    switch k.textBaseline {
    case 0: baselineY = y
    case 1: baselineY = y + (ascentPx + descentPx) / 2
    case 3: baselineY = y + descentPx
    default: baselineY = y + ascentPx
    }
    let a = Float(rgba & 0xFF) / 255 * k.alpha
    let color = SDL_FColor(r: Float((rgba >> 24) & 0xFF) / 255,
                           g: Float((rgba >> 16) & 0xFF) / 255,
                           b: Float((rgba >> 8) & 0xFF) / 255,
                           a: a)
    let dpr = max(1, k.baseScale)
    let rasterPx = Int32(Float(sizePx) * dpr + 0.5)
    var pen = x
    for i in 0..<cps.count {
        let cp = cps[i]
        if cp == 0xFE0F || cp == 0x200D { continue }
        if kit_font_glyph_index(info, cp) == 0, let eg = k.emojiGlyph(cp), let tex = eg.tex {
            let escale = Float(sizePx) / Float(eg.ppem)
            k.drawTexturedQuad(tex,
                               pen + Float(eg.bearingX) * escale, baselineY - Float(eg.bearingY) * escale,
                               Float(eg.w) * escale, Float(eg.h) * escale,
                               0, 0, 1, 1, SDL_FColor(r: 1, g: 1, b: 1, a: a))
            pen += Float(eg.advance) * escale + spacing
            continue
        }
        let fid = font > 0 ? font : k.defaultFont
        if let g = k.glyph(fid, info, cp, rasterPx), let tex = g.tex {
            k.drawTexturedQuad(tex,
                               pen + Float(g.xoff) / dpr, baselineY + Float(g.yoff) / dpr,
                               Float(g.w) / dpr, Float(g.h) / dpr,
                               0, 0, 1, 1, color)
        }
        var advance: Int32 = 0
        var lsb: Int32 = 0
        kit_font_hmetrics(info, cp, &advance, &lsb)
        pen += Float(advance) * scale + spacing
        if i + 1 < cps.count {
            pen += Float(kit_font_kern(info, cp, cps[i + 1])) * scale
        }
    }
}

// MARK: - shadows, filters, composite (approximations where SDL has no blur)

@_cdecl("gfx_draw_shadow_image")
func gfx_draw_shadow_image(_ img: Int32, _ x: Float, _ y: Float, _ w: Float, _ h: Float, _ blur: Float, _ rgba: UInt32) {
    let k = Kit.shared
    guard img > 0, Int(img) < k.images.count, let rec = k.images[Int(img)], let tex = rec.tex else { return }
    let a = Float(rgba & 0xFF) / 255 * k.alpha
    _ = SDL_SetTextureColorModFloat(tex, Float((rgba >> 24) & 0xFF) / 255,
                                    Float((rgba >> 16) & 0xFF) / 255,
                                    Float((rgba >> 8) & 0xFF) / 255)
    let r = max(1, blur / 3)
    let offsets: [(Float, Float)] = [(0, 0), (r, 0), (-r, 0), (0, r), (0, -r)]
    for (ox, oy) in offsets {
        let color = SDL_FColor(r: 1, g: 1, b: 1, a: a / Float(offsets.count))
        k.drawTexturedQuad(tex, x + ox, y + oy, w, h, 0, 0, 1, 1, color)
    }
    _ = SDL_SetTextureColorModFloat(tex, 1, 1, 1)
}

@_cdecl("gfx_set_shadow")
func gfx_set_shadow(_ blurRadius: Float, _ dx: Float, _ dy: Float, _ rgba: UInt32) {}

@_cdecl("gfx_clear_shadow")
func gfx_clear_shadow() {}

@_cdecl("gfx_set_filter")
func gfx_set_filter(_ utf8: UnsafePointer<CChar>?, _ len: Int32) {}

@_cdecl("gfx_clear_filter")
func gfx_clear_filter() {}

@_cdecl("gfx_set_composite")
func gfx_set_composite(_ mode: Int32) {
    Kit.shared.additive = mode == 1
}

@_cdecl("gfx_snap_translation")
func gfx_snap_translation() {
    let k = Kit.shared
    k.mat.e = SDL_roundf(k.mat.e)
    k.mat.f = SDL_roundf(k.mat.f)
}

@_cdecl("gfx_set_line_style")
func gfx_set_line_style(_ join: Int32, _ cap: Int32, _ miterLimit: Float) {}

// MARK: - assets

@_cdecl("asset_exists")
func asset_exists(_ name: UnsafePointer<CChar>?, _ len: Int32) -> Int32 {
    let k = Kit.shared
    return k.assetBytes(k.cString(name, len)) != nil ? 1 : 0
}

@_cdecl("asset_text")
func asset_text(_ name: UnsafePointer<CChar>?, _ len: Int32, _ buf: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    let k = Kit.shared
    guard let data = k.assetBytes(k.cString(name, len)) else { return -1 }
    if let buf {
        let n = min(Int(cap), data.count)
        for i in 0..<n { buf[i] = CChar(bitPattern: data[i]) }
    }
    return Int32(data.count)
}

// MARK: - sound extensions

@_cdecl("snd_create_pcm")
func snd_create_pcm(_ samples: UnsafePointer<Float>?, _ frameCount: Int32, _ sampleRate: Int32) -> Int32 {
    let k = Kit.shared
    guard let samples, frameCount > 0 else { return 0 }
    let id = Int32(k.soundSpecs.count)
    var spec = SDL_AudioSpec()
    spec.format = SDL_AUDIO_F32LE
    spec.channels = 1
    spec.freq = sampleRate > 0 ? sampleRate : 44100
    let byteLen = Int(frameCount) * 4
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: byteLen)
    let src = UnsafeRawPointer(samples)
    let dst = UnsafeMutableRawPointer(buf)
    dst.copyMemory(from: src, byteCount: byteLen)
    k.soundSpecs.append(spec)
    k.soundBufs.append(buf)
    k.soundLens.append(UInt32(byteLen))
    return id
}

@_cdecl("snd_status")
func snd_status(_ voice: Int32) -> Int32 {
    let k = Kit.shared
    for v in k.voiceIds where v == voice { return 1 }
    return 0
}

@_cdecl("snd_pause_all")
func snd_pause_all() {
    let k = Kit.shared
    if k.audioDevice != 0 { _ = SDL_PauseAudioDevice(k.audioDevice) }
}

@_cdecl("snd_resume_all")
func snd_resume_all() {
    let k = Kit.shared
    if k.audioDevice != 0 { _ = SDL_ResumeAudioDevice(k.audioDevice) }
}

@_cdecl("snd_set_rate")
func snd_set_rate(_ voice: Int32, _ rate: Float) {
    let k = Kit.shared
    for i in 0..<k.voiceIds.count where k.voiceIds[i] == voice {
        _ = SDL_SetAudioStreamFrequencyRatio(k.voiceStreams[i], max(0.0625, min(16, rate)))
        return
    }
}

// MARK: - AVAudioEngine shim mapped onto voices

@_cdecl("eng_player_create")
func eng_player_create() -> Int32 {
    let k = Kit.shared
    let id = k.nextEngId
    k.nextEngId += 1
    k.engPlayers[id] = (sound: 0, loops: 0, voice: 0)
    k.engVolumes[id] = 1
    return id
}

@_cdecl("eng_player_release")
func eng_player_release(_ id: Int32) {
    let k = Kit.shared
    if let p = k.engPlayers[id], p.voice != 0 { k.stopVoice(p.voice) }
    k.engPlayers[id] = nil
    k.engVolumes[id] = nil
}

@_cdecl("eng_mixer_create")
func eng_mixer_create() -> Int32 {
    let k = Kit.shared
    let id = k.nextEngId
    k.nextEngId += 1
    k.engVolumes[id] = 1
    return id
}

@_cdecl("eng_node_set_volume")
func eng_node_set_volume(_ id: Int32, _ v: Float) {
    let k = Kit.shared
    k.engVolumes[id] = v
    if let p = k.engPlayers[id], p.voice != 0 { k.setVoiceVolume(p.voice, v * 100) }
}

@_cdecl("eng_node_set_pan")
func eng_node_set_pan(_ id: Int32, _ p: Float) {
    let k = Kit.shared
    if let player = k.engPlayers[id], player.voice != 0 { k.setVoicePan(player.voice, p) }
}

@_cdecl("eng_connect")
func eng_connect(_ src: Int32, _ dst: Int32) {}

@_cdecl("eng_player_schedule_buffer")
func eng_player_schedule_buffer(_ player: Int32, _ sound: Int32, _ loops: Int32) -> Int32 {
    let k = Kit.shared
    guard var p = k.engPlayers[player] else { return 0 }
    p.sound = sound
    p.loops = loops
    k.engPlayers[player] = p
    return 1
}

@_cdecl("eng_player_play")
func eng_player_play(_ id: Int32) {
    let k = Kit.shared
    guard var p = k.engPlayers[id], p.sound > 0 else { return }
    if p.voice != 0 { k.stopVoice(p.voice) }
    let vol = k.engVolumes[id] ?? 1
    p.voice = k.play(p.sound, volume: vol * 100, loop: p.loops != 0)
    k.engPlayers[id] = p
}

@_cdecl("eng_player_stop")
func eng_player_stop(_ id: Int32) {
    let k = Kit.shared
    guard var p = k.engPlayers[id] else { return }
    if p.voice != 0 { k.stopVoice(p.voice) }
    p.voice = 0
    k.engPlayers[id] = p
}

@_cdecl("eng_start")
func eng_start() {}

@_cdecl("eng_stop")
func eng_stop() {}

// MARK: - window

@_cdecl("win_width")
func win_width() -> Int32 { Int32(Kit.shared.logicalW) }

@_cdecl("win_height")
func win_height() -> Int32 { Int32(Kit.shared.logicalH) }

@_cdecl("win_set_title")
func win_set_title(_ s: UnsafePointer<CChar>?, _ len: Int32) {
    let k = Kit.shared
    _ = k.cString(s, len).withCString { SDL_SetWindowTitle(k.window, $0) }
}

@_cdecl("win_request_fullscreen")
func win_request_fullscreen() {
    let k = Kit.shared
    _ = SDL_SetWindowFullscreen(k.window, true)
    k.fullscreen = true
}

@_cdecl("win_exit_fullscreen")
func win_exit_fullscreen() {
    let k = Kit.shared
    _ = SDL_SetWindowFullscreen(k.window, false)
    k.fullscreen = false
}

@_cdecl("win_download")
func win_download(_ name: UnsafePointer<CChar>?, _ nlen: Int32, _ data: UnsafePointer<CChar>?, _ dlen: Int32) {
    let k = Kit.shared
    guard let data, dlen > 0 else { return }
    _ = k.cString(name, nlen).withCString { SDL_SaveFile($0, data, Int(dlen)) }
}
