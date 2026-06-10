import KitABI

// Looping / ambient audio attached to the scene graph. Maps onto the kit's
// snd_play (with loop=1 for autoplayLooped). isPositional is recorded but
// the runtime mixes in mono — Web Audio panning would slot in here later.
//
// AsteroidZ uses these for the saucer drone (run + changeVolume). FrogMan's
// AVAudioEngine paths bypass this and go straight to AVAudioPlayer when we
// ship the AVFoundation shim.
public final class SKAudioNode: SKNode {
    public var autoplayLooped: Bool = true
    public var isPositional: Bool = true
    public var volume: Float = 1.0 { didSet { applyVolume() } }

    let fileName: String
    var buffer: Int32 = 0      // snd_by_name handle
    var voice: Int32 = -1      // snd_play voice handle, -1 when idle

    public init(fileNamed name: String) {
        self.fileName = name
        super.init()
        self.buffer = withUTF8Ptr(name) { snd_by_name($0, $1) }
    }
    // URL form: takes anything with a `lastPathComponent`, so games passing
    // Foundation `URL` work without us importing Foundation here.
    public init(url: URL) {
        self.fileName = url.lastPathComponent
        super.init()
        self.buffer = withUTF8Ptr(self.fileName) { snd_by_name($0, $1) }
    }

    var manuallyPaused = false

    func autoplayTick() {
        if autoplayLooped, voice < 0, !manuallyPaused, buffer != 0 { play() }
        positionalTick()
    }

    // Apple's positional default: volume fades with distance off the scene
    // and the voice pans by horizontal offset (both saucer drones get this).
    func positionalTick() {
        guard isPositional, voice >= 0 else { return }
        var x = position.x
        var y = position.y
        var sceneW: CGFloat = 0
        var sceneH: CGFloat = 0
        var p = parent
        while let node = p {
            if let sc = node as? SKScene {
                sceneW = sc.size.width
                sceneH = sc.size.height
                break
            }
            x += node.position.x
            y += node.position.y
            p = node.parent
        }
        guard sceneW > 0 else { return }
        let pan = max(-1, min(1, (x - sceneW / 2) / (sceneW / 2) * 0.8))
        var fade: CGFloat = 1
        let margin: CGFloat = 300
        if x < 0 { fade = min(fade, max(0, 1 + x / margin)) }
        if x > sceneW { fade = min(fade, max(0, 1 - (x - sceneW) / margin)) }
        if y < 0 { fade = min(fade, max(0, 1 + y / margin)) }
        if y > sceneH { fade = min(fade, max(0, 1 - (y - sceneH) / margin)) }
        snd_set_volume(voice, volume * 100 * Float(fade))
        snd_set_pan(voice, Float(pan))
    }

    public func play() {
        if buffer == 0 { return }
        manuallyPaused = false
        if voice >= 0 { snd_stop(voice) }
        voice = snd_play(buffer, volume * 100, autoplayLooped ? 1 : 0)
    }
    public func pause() {
        manuallyPaused = true
        if voice >= 0 { snd_stop(voice) }
        voice = -1
    }
    public func stop()  { pause() }

    public override func removeFromParent() {
        stop()
        super.removeFromParent()
    }

    func applyVolume() { if voice >= 0 { snd_set_volume(voice, volume * 100) } }
}

public extension SKAction {
    // Node-targeted audio actions: `audioNode.run(.play(on: audioNode))` etc.
    static func play(on node: SKAudioNode) -> SKAction { SKAction.run { node.play() } }
    static func stop(on node: SKAudioNode) -> SKAction { SKAction.run { node.stop() } }
}

