import KitABI

// SKKeyframeSequence: keyframe interpolation table for SKEmitterNode's
// per-particle color/alpha/scale sequences. SpriteKit games typically
// reference these through the Particle Editor (.sks files), then read
// them back via the SKEmitterNode property setters. We expose the API
// so emitter code compiles; sampling returns the linear-interpolated
// value across keyframes for the obvious numeric types (CGFloat, SKColor,
// CGVector).
public enum SKKeyframeInterpolationMode { case linear, spline, step }
public enum SKRepeatMode { case clamp, loop }

// Typed keyframe value so the sequence holds no existentials and compiles
// under Embedded Swift. Accessors pull the concrete payload back out.
public enum SKKeyframeValue {
    case number(Double)
    case vector(CGVector)
    case color(SKColor)

    public var cgFloat: CGFloat? { if case .number(let n) = self { return CGFloat(n) }; return nil }
    public var vector: CGVector? { if case .vector(let v) = self { return v }; return nil }
    public var color: SKColor? { if case .color(let c) = self { return c }; return nil }
}

public final class SKKeyframeSequence {
    public var interpolationMode: SKKeyframeInterpolationMode = .linear
    public var repeatMode: SKRepeatMode = .clamp

    var values: [SKKeyframeValue] = []
    var times: [Double] = []

    public init() {}
    public init(capacity: Int) {
        values.reserveCapacity(capacity)
        times.reserveCapacity(capacity)
    }
    public init(keyframeValues vs: [SKKeyframeValue], times ts: [Double]) {
        self.values = vs
        self.times = ts
    }
    public var count: Int { values.count }

    public func addKeyframeValue(_ value: SKKeyframeValue, time: Double) {
        values.append(value)
        times.append(time)
    }
    public func removeKeyframe(at index: Int) {
        guard index >= 0, index < values.count else { return }
        values.remove(at: index)
        times.remove(at: index)
    }
    public func removeLastKeyframe() {
        _ = values.popLast()
        _ = times.popLast()
    }
    public func getKeyframeValue(at index: Int) -> SKKeyframeValue? {
        (index >= 0 && index < values.count) ? values[index] : nil
    }
    public func setKeyframeValue(_ value: SKKeyframeValue, for index: Int) {
        if index >= 0, index < values.count { values[index] = value }
    }
    public func getKeyframeTime(at index: Int) -> Double {
        (index >= 0 && index < times.count) ? times[index] : 0
    }
    public func setKeyframeTime(_ time: Double, for index: Int) {
        if index >= 0, index < times.count { times[index] = time }
    }

    // Sample at arbitrary time. Numeric types are lerped; mismatched cases
    // return the nearest keyframe. Use the SKKeyframeValue accessors for
    // CGFloat / SKColor / CGVector sampling.
    public func sample(atTime t: Double) -> SKKeyframeValue? {
        guard !values.isEmpty else { return nil }
        if t <= times[0] { return values[0] }
        if t >= times.last! { return values.last }
        for i in 1..<times.count {
            if t < times[i] {
                let span = times[i] - times[i-1]
                let p = span == 0 ? 0 : (t - times[i-1]) / span
                return lerp(values[i-1], values[i], CGFloat(p))
            }
        }
        return values.last
    }

    private func lerp(_ a: SKKeyframeValue, _ b: SKKeyframeValue, _ p: CGFloat) -> SKKeyframeValue {
        switch (a, b) {
        case let (.number(an), .number(bn)):
            return .number(an + (bn - an) * Double(p))
        case let (.vector(av), .vector(bv)):
            return .vector(CGVector(dx: av.dx + (bv.dx - av.dx) * p, dy: av.dy + (bv.dy - av.dy) * p))
        case let (.color(ac), .color(bc)):
            return .color(SKColor(red:   ac.r + (bc.r - ac.r) * p,
                                  green: ac.g + (bc.g - ac.g) * p,
                                  blue:  ac.b + (bc.b - ac.b) * p,
                                  alpha: ac.a + (bc.a - ac.a) * p))
        default:
            return p < 0.5 ? a : b
        }
    }
}
