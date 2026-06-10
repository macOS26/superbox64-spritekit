// Frame-driven Foundation stand-ins. WASI has no runloop, so anything Apple
// schedules on one (Timer, DispatchQueue.main, notification delivery) is
// driven from SKView.tick once per frame via KitRunLoop. Single-threaded wasm
// makes the unsynchronised globals safe.

// MARK: - KitRunLoop (the per-frame pump other shims and modules hook into)

public enum KitRunLoop {
    nonisolated(unsafe) private static var perFrame: [() -> Void] = []

    public static func addPerFrameHook(_ hook: @escaping () -> Void) {
        perFrame.append(hook)
    }

    public static func _tick(_ dt: Double) {
        Timer._tick(dt)
        DispatchQueue._tick(dt)
        for hook in perFrame { hook() }
    }
}

// MARK: - Timer

public final class Timer {
    public var tolerance: Double = 0
    public private(set) var isValid = true
    let interval: Double
    let repeats: Bool
    let block: (Timer) -> Void
    var remaining: Double

    nonisolated(unsafe) private static var scheduled: [Timer] = []

    init(interval: Double, repeats: Bool, block: @escaping (Timer) -> Void) {
        self.interval = interval
        self.repeats = repeats
        self.block = block
        self.remaining = interval
    }

    @discardableResult
    public static func scheduledTimer(withTimeInterval interval: Double, repeats: Bool,
                                      block: @escaping (Timer) -> Void) -> Timer {
        let t = Timer(interval: interval, repeats: repeats, block: block)
        scheduled.append(t)
        return t
    }

    public func invalidate() { isValid = false }

    static func _tick(_ dt: Double) {
        var fired: [Timer] = []
        for t in scheduled where t.isValid {
            t.remaining -= dt
            if t.remaining <= 0 {
                fired.append(t)
                if t.repeats { t.remaining = t.interval } else { t.isValid = false }
            }
        }
        scheduled.removeAll { !$0.isValid }
        for t in fired where t.isValid || !t.repeats { t.block(t) }
    }
}

// MARK: - RunLoop (Apple games add timers to it; scheduledTimer already runs them)

public final class RunLoop {
    public static let current = RunLoop()
    public static let main = RunLoop()
    public struct Mode {
        public static let common = Mode()
        public static let `default` = Mode()
    }
    public func add(_ timer: Timer, forMode mode: Mode) {}
}

// MARK: - DispatchQueue (main only; deadlines resolve against frame time)

public struct DispatchTime {
    let offset: Double
    public static func now() -> DispatchTime { DispatchTime(offset: 0) }
    public static func + (lhs: DispatchTime, rhs: Double) -> DispatchTime {
        DispatchTime(offset: lhs.offset + rhs)
    }
}

public final class DispatchQueue {
    public static let main = DispatchQueue()

    nonisolated(unsafe) private static var pending: [(remaining: Double, work: () -> Void)] = []

    public func async(execute work: @escaping () -> Void) {
        DispatchQueue.pending.append((0, work))
    }
    public func asyncAfter(deadline: DispatchTime, execute work: @escaping () -> Void) {
        DispatchQueue.pending.append((deadline.offset, work))
    }

    static func _tick(_ dt: Double) {
        var due: [() -> Void] = []
        for i in pending.indices {
            pending[i].remaining -= dt
            if pending[i].remaining <= 0 { due.append(pending[i].work) }
        }
        pending.removeAll { $0.remaining <= 0 }
        for work in due { work() }
    }
}

// MARK: - Notification / NotificationCenter

public struct Notification {
    public struct Name: Hashable, RawRepresentable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ raw: String) { self.rawValue = raw }
    }
    public let name: Name
    public let object: Any?
    public init(name: Name, object: Any? = nil) {
        self.name = name
        self.object = object
    }
}

public final class NotificationCenter {
    public static let `default` = NotificationCenter()
    public final class ObserverToken {}

    private var observers: [(name: Notification.Name?, token: ObserverToken, block: (Notification) -> Void)] = []

    @discardableResult
    public func addObserver(forName name: Notification.Name?, object: Any?, queue: Any?,
                            using block: @escaping (Notification) -> Void) -> ObserverToken {
        let token = ObserverToken()
        observers.append((name, token, block))
        return token
    }

    public func post(name: Notification.Name, object: Any?) {
        let note = Notification(name: name, object: object)
        for o in observers where o.name == nil || o.name == name { o.block(note) }
    }

    public func removeObserver(_ token: Any) {
        if let t = token as? ObserverToken {
            observers.removeAll { $0.token === t }
        }
    }
}

// MARK: - NSMutableDictionary (SKNode.userData's Apple type)

public final class NSMutableDictionary {
    private var storage: [String: Any] = [:]
    public init() {}
    public var count: Int { storage.count }
    public subscript(key: String) -> Any? {
        get { storage[key] }
        set { storage[key] = newValue }
    }
}
