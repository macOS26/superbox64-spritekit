# superbox64-spritekit

A Swift reimplementation of Apple's SpriteKit that compiles to WebAssembly via WASI Preview 1. A macOS or iOS SpriteKit game adds this package, keeps every `import SpriteKit` unchanged, and runs in any modern browser with no source edits.

No Emscripten. No loading screens. No watermarks.

**Live demo:** [boss-man.us/play](https://boss-man.us/play)

**Runtime:** [superbox64-wasmkit](https://github.com/macOS26/superbox64-wasmkit) — the JavaScript runtime that loads and drives the WASM binary

---

## Quick Start

### 1. Add the package

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/macOS26/superbox64-spritekit", branch: "main"),
],
targets: [
    .executableTarget(
        name: "MyGame",
        dependencies: [
            .product(name: "SpriteKit",   package: "superbox64-spritekit"),
            .product(name: "AppKit",      package: "superbox64-spritekit"),
            .product(name: "GameKit",     package: "superbox64-spritekit"),
            .product(name: "AVFoundation",package: "superbox64-spritekit"),
        ],
        swiftSettings: [.defaultIsolation(MainActor.self)],
        linkerSettings: [.unsafeFlags([
            "-Xclang-linker", "-mexec-model=reactor",
            "-Xlinker", "--export=boot",
            "-Xlinker", "--export=frame",
            "-Xlinker", "--export-if-defined=_initialize",
            "-Xlinker", "--allow-undefined",
        ])]
    ),
]
```

### 2. Write the entry points

```swift
// main.swift
import SpriteKit

@_cdecl("boot")
nonisolated func boot() {
    MainActor.assumeIsolated {
        let view = SKView(frame: CGRect(x: 0, y: 0, width: 1184, height: 666))
        view.presentScene(GameScene(size: CGSize(width: 1184, height: 666)))
    }
}

@_cdecl("frame")
nonisolated func frame(_ dtMs: Double) {
    MainActor.assumeIsolated {
        SKView.current?.update(dtMs / 1000.0)
    }
}
```

### 3. Write the scene — same as macOS

```swift
// GameScene.swift
import SpriteKit

final class GameScene: SKScene {

    override func didMove(to view: SKView) {
        backgroundColor = .black

        let label = SKLabelNode(text: "Hello from WASM")
        label.fontName = "MarkerFelt-Wide"
        label.fontSize = 48
        label.fontColor = .white
        label.position = CGPoint(x: size.width / 2, y: size.height / 2)
        addChild(label)

        label.run(.repeatForever(.sequence([
            .fadeOut(withDuration: 1.0),
            .fadeIn(withDuration: 1.0),
        ])))
    }

    override func update(_ currentTime: TimeInterval) {
    }
}
```

### 4. Build

```bash
xcrun --toolchain swift swift build \
    --swift-sdk swift-6.3.2-RELEASE_wasm \
    -c release
```

The output is a WASM reactor at `.build/wasm32-unknown-wasip1/release/MyGame.wasm`. Serve it with [superbox64-wasmkit](https://github.com/macOS26/superbox64-wasmkit).

---

## What Is Included

### SpriteKit

| Type | Coverage |
|---|---|
| `SKScene` | `didMove(to:)`, `update(_:)`, `didFinishUpdate()`, `willMove(from:)`, `presentScene`, `camera`, `physicsWorld` |
| `SKNode` | Full tree: `addChild`, `removeFromParent`, `children`, `parent`, `name`, `zPosition`, `alpha`, `isHidden`, `xScale/yScale`, `zRotation`, `position`, `run(_:)`, `action(forKey:)` |
| `SKSpriteNode` | Texture, color, colorBlendFactor, anchorPoint, size, blending modes |
| `SKLabelNode` | fontName, fontSize, fontColor, horizontalAlignmentMode, verticalAlignmentMode, preferredMaxLayoutWidth |
| `SKShapeNode` | fillColor, strokeColor, lineWidth, path, `.init(circleOfRadius:)`, `.init(rect:)` |
| `SKEmitterNode` | Particle emitter (position, velocity, lifetime, color range) |
| `SKCameraNode` | Position, scale, xScale/yScale |
| `SKCropNode` | maskNode-based cropping |
| `SKAction` | `moveBy/To`, `scaleTo/By`, `fadeIn/Out`, `fadeAlphaTo`, `rotate`, `sequence`, `group`, `repeatForever`, `wait`, `run`, `setTexture`, `colorize`, `customAction` |
| `SKTexture` | Image textures, color textures, `textureRect`, `size` |
| `SKView` | Canvas-backed, `presentScene`, `texture(from:)`, `ignoresSiblingOrder` |
| `SKTransition` | `fade`, `crossFade`, `doorsOpenHorizontal`, `push`, `reveal`, `moveIn` |
| `SKPhysicsBody` | `dynamic`, bit masks, `velocity`, `applyImpulse`, `isDynamic`, `affectedByGravity` |
| `SKPhysicsWorld` | `gravity`, `contactDelegate`, `enumerateBodies(inRect:)` |
| `CGPath / CGMutablePath` | `addLine`, `addArc`, `addCurve`, `closeSubpath` |
| `CGAffineTransform` | Full matrix transform |

### Platform Shims

Add the modules your game imports. On macOS they resolve to Apple's frameworks. On WASM they resolve to these shims.

| Module | Provides |
|---|---|
| `AppKit` | `NSColor`, `NSFont`, `NSImage`, `NSEvent`, `NSWindow`, `NSScreen`, `NSApplication` |
| `UIKit` | `UIColor`, `UIFont`, `UIImage`, `UIViewController`, `UIScreen`, `UIDevice` |
| `GameKit` | `GKLocalPlayer`, `GKLeaderboard`, `GKScore`, `GKAchievement` |
| `GameplayKit` | `GKRandomDistribution`, `GKShuffledDistribution`, `GKMersenneTwisterRandomSource` |
| `GameController` | `GCController`, `GCExtendedGamepad`, `GCControllerDirectionPad` |
| `AVFoundation` | `AVAudioPlayer`, `AVSpeechSynthesizer`, `AVSpeechUtterance` |
| `AudioToolbox` | `AudioServicesPlaySystemSound` |
| `Combine` | `PassthroughSubject`, `CurrentValueSubject`, `AnyCancellable` |
| `SwiftUI` | `Color`, `View` stubs |

### Physics (Box2D 2.4.1)

`Box2DBridge` ships with the package. `SKPhysicsBody` and `SKPhysicsWorld` map directly to Box2D bodies, fixtures, joints, and contacts.

---

## Requirements

- Swift 6.3.2+ toolchain from swift.org
- `swift-6.3.2-RELEASE_wasm` SDK installed via `swift sdk install`

---

## Related

- [superbox64-wasmkit](https://github.com/macOS26/superbox64-wasmkit) — JavaScript runtime, host page, and C++ SFML shim
- [Boss-Man](https://github.com/macOS26/Boss-Man) — full arcade game built with this engine, shipping on 6 platforms from one Swift source

---

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). Apache 2.0 grants an explicit patent license and terminates it on patent litigation, protecting contributors and users from patent ambush. Bundles Box2D 2.4.1 (MIT, Erin Catto).
