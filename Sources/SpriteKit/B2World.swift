import CBox2D

// MARK: - Box2D v3 backend (replaces the C++ cbox2d bridge; Swift calls C directly)

// Coordinates are SpriteKit points treated as Box2D length units. Telling Box2D
// the unit scale keeps its internal tolerances (linear slop, speculative contact
// distance, sleep thresholds) proportionate to pixel-sized worlds, and the
// explicit speed cap leaves velocity-driven bodies unclamped at gameplay speeds.
enum B2 {
    nonisolated(unsafe) static var world: b2WorldId? = nil
    nonisolated(unsafe) static var bodies: [b2BodyId?] = []
    nonisolated(unsafe) static var joints: [b2JointId?] = []
    nonisolated(unsafe) private static var unitsConfigured = false

    struct BeginContact {
        let catA: UInt32
        let catB: UInt32
        let bodyA: Int32
        let bodyB: Int32
    }

    static func reset(_ gx: Float, _ gy: Float) {
        if let w = world { b2DestroyWorld(w) }
        if !unitsConfigured {
            b2SetLengthUnitsPerMeter(100.0)
            unitsConfigured = true
        }
        var def = b2DefaultWorldDef()
        def.gravity = b2Vec2(x: gx, y: gy)
        def.maximumLinearSpeed = 4000.0
        world = b2CreateWorld(&def)
        bodies.removeAll()
        joints.removeAll()
    }

    private static func ensureWorld() -> b2WorldId {
        if world == nil { reset(0, 0) }
        return world!
    }

    // Bodies are addressed by a stable Int32 slot (the registry key); removal
    // nulls the slot so older ids never alias a newer body. The Box2D-side
    // userData carries slot+1 (0 would decode as a nil pointer).
    private static func newBody(_ x: Float, _ y: Float, _ dynamic: Bool) -> (Int32, b2BodyId) {
        let w = ensureWorld()
        var bd = b2DefaultBodyDef()
        bd.type = dynamic ? b2_dynamicBody : b2_staticBody
        bd.position = b2Vec2(x: x, y: y)
        let id = Int32(bodies.count)
        bd.userData = UnsafeMutableRawPointer(bitPattern: Int(id) + 1)
        let body = b2CreateBody(w, &bd)
        bodies.append(body)
        return (id, body)
    }

    // Apple's contactTest/collision split is emulated upstream (SKPhysicsBody
    // feeds the union mask + sensor flag); every shape opts into both event
    // streams so sensor and solid pairs alike surface in drainBeginContacts.
    private static func shapeDef(_ cat: UInt32, _ mask: UInt32, _ sensor: Bool) -> b2ShapeDef {
        var sd = b2DefaultShapeDef()
        sd.density = 1.0
        sd.material.friction = 0.2
        sd.material.restitution = 0.1
        sd.filter.categoryBits = UInt64(cat)
        sd.filter.maskBits = UInt64(mask)
        sd.isSensor = sensor
        sd.enableSensorEvents = true
        sd.enableContactEvents = true
        return sd
    }

    static func addBox(_ x: Float, _ y: Float, _ hw: Float, _ hh: Float,
                       _ dynamic: Bool, _ cat: UInt32, _ mask: UInt32, _ sensor: Bool) -> Int32 {
        let (id, body) = newBody(x, y, dynamic)
        var sd = shapeDef(cat, mask, sensor)
        var poly = b2MakeBox(hw, hh)
        b2CreatePolygonShape(body, &sd, &poly)
        return id
    }

    static func addCircle(_ x: Float, _ y: Float, _ r: Float,
                          _ dynamic: Bool, _ cat: UInt32, _ mask: UInt32, _ sensor: Bool) -> Int32 {
        let (id, body) = newBody(x, y, dynamic)
        var sd = shapeDef(cat, mask, sensor)
        var circle = b2Circle(center: b2Vec2(x: 0, y: 0), radius: r)
        b2CreateCircleShape(body, &sd, &circle)
        return id
    }

    // Convex polygon in body-local coordinates. Box2D caps the vertex count and
    // requires convexity (the hull pass enforces it); degenerate hulls fall back
    // to the caller's box path via the negative return.
    static func addPolygon(_ x: Float, _ y: Float, _ pts: [Float],
                           _ dynamic: Bool, _ cat: UInt32, _ mask: UInt32, _ sensor: Bool) -> Int32 {
        let maxVerts = Int(B2_MAX_POLYGON_VERTICES)
        let n = min(pts.count / 2, maxVerts)
        if n < 3 { return -1 }
        var verts = [b2Vec2]()
        verts.reserveCapacity(n)
        for i in 0..<n { verts.append(b2Vec2(x: pts[i*2], y: pts[i*2+1])) }
        let hull = verts.withUnsafeBufferPointer { b2ComputeHull($0.baseAddress, Int32(n)) }
        if hull.count < 3 { return -1 }
        let (id, body) = newBody(x, y, dynamic)
        var sd = shapeDef(cat, mask, sensor)
        var h = hull
        var poly = b2MakePolygon(&h, 0)
        b2CreatePolygonShape(body, &sd, &poly)
        return id
    }

    static func addEdge(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float,
                        _ cat: UInt32, _ mask: UInt32) -> Int32 {
        let (id, body) = newBody(0, 0, false)
        var sd = shapeDef(cat, mask, false)
        var seg = b2Segment(point1: b2Vec2(x: x1, y: y1), point2: b2Vec2(x: x2, y: y2))
        b2CreateSegmentShape(body, &sd, &seg)
        return id
    }

    // Polyline / closed loop as individual two-sided segments on one static
    // body. v3 chain shapes are one-sided with a winding requirement; discrete
    // segments keep the 2.4 two-sided behavior the games were written against.
    static func addChain(_ pts: [Float], closed: Bool, _ cat: UInt32, _ mask: UInt32) -> Int32 {
        let n = pts.count / 2
        if n < 2 { return -1 }
        let (id, body) = newBody(0, 0, false)
        var sd = shapeDef(cat, mask, false)
        for i in 0..<(closed ? n : n - 1) {
            let j = (i + 1) % n
            var seg = b2Segment(point1: b2Vec2(x: pts[i*2], y: pts[i*2+1]),
                                point2: b2Vec2(x: pts[j*2], y: pts[j*2+1]))
            b2CreateSegmentShape(body, &sd, &seg)
        }
        return id
    }

    private static func body(_ id: Int32) -> b2BodyId? {
        guard id >= 0, Int(id) < bodies.count else { return nil }
        return bodies[Int(id)]
    }

    static func removeBody(_ id: Int32) {
        guard let b = body(id) else { return }
        b2DestroyBody(b)
        bodies[Int(id)] = nil
    }

    static func setVelocity(_ id: Int32, _ vx: Float, _ vy: Float) {
        guard let b = body(id) else { return }
        b2Body_SetLinearVelocity(b, b2Vec2(x: vx, y: vy))
    }

    static func setTransform(_ id: Int32, _ x: Float, _ y: Float, _ angle: Float) {
        guard let b = body(id) else { return }
        let p = b2Body_GetPosition(b)
        let a = b2Rot_GetAngle(b2Body_GetRotation(b))
        if p.x == x && p.y == y && a == angle { return }
        b2Body_SetTransform(b, b2Vec2(x: x, y: y), b2MakeRot(angle))
        // SetTransform refreshes the broad phase but does not wake the body.
        // Game-driven bodies move by teleport with zero velocity, so without
        // the wake they fall asleep and their contact pairs stop being
        // evaluated — didBegin never fires. Waking on a real move keeps the
        // pair live, matching Apple SpriteKit where node-driven bodies always
        // report contacts.
        b2Body_SetAwake(b, true)
    }

    static func getPosition(_ id: Int32) -> (Float, Float) {
        guard let b = body(id) else { return (0, 0) }
        let p = b2Body_GetPosition(b)
        return (p.x, p.y)
    }

    static func getAngle(_ id: Int32) -> Float {
        guard let b = body(id) else { return 0 }
        return b2Rot_GetAngle(b2Body_GetRotation(b))
    }

    static func applyForce(_ id: Int32, _ fx: Float, _ fy: Float) {
        guard let b = body(id) else { return }
        b2Body_ApplyForceToCenter(b, b2Vec2(x: fx, y: fy), true)
    }

    static func applyImpulse(_ id: Int32, _ ix: Float, _ iy: Float) {
        guard let b = body(id) else { return }
        b2Body_ApplyLinearImpulseToCenter(b, b2Vec2(x: ix, y: iy), true)
    }

    static func applyTorque(_ id: Int32, _ t: Float) {
        guard let b = body(id) else { return }
        b2Body_ApplyTorque(b, t, true)
    }

    static func applyAngularImpulse(_ id: Int32, _ i: Float) {
        guard let b = body(id) else { return }
        b2Body_ApplyAngularImpulse(b, i, true)
    }

    static func setAngularVelocity(_ id: Int32, _ w: Float) {
        guard let b = body(id) else { return }
        b2Body_SetAngularVelocity(b, w)
    }

    static func getAngularVelocity(_ id: Int32) -> Float {
        guard let b = body(id) else { return 0 }
        return b2Body_GetAngularVelocity(b)
    }

    static func step(_ dt: Float) {
        guard let w = world else { return }
        b2World_Step(w, dt, 4)
    }

    // MARK: - Joints

    private static func storeJoint(_ j: b2JointId) -> Int32 {
        let id = Int32(joints.count)
        joints.append(j)
        return id
    }

    static func removeJoint(_ id: Int32) {
        guard id >= 0, Int(id) < joints.count, let j = joints[Int(id)] else { return }
        b2DestroyJoint(j)
        joints[Int(id)] = nil
    }

    private static func relativeAngle(_ a: b2BodyId, _ b: b2BodyId) -> Float {
        b2Rot_GetAngle(b2Body_GetRotation(b)) - b2Rot_GetAngle(b2Body_GetRotation(a))
    }

    static func addJointPin(_ a: Int32, _ b: Int32, _ ax: Float, _ ay: Float,
                            enableLimits: Bool, _ lower: Float, _ upper: Float,
                            _ frictionTorque: Float, _ motorSpeed: Float) -> Int32 {
        guard let w = world, let ba = body(a), let bb = body(b) else { return -1 }
        let anchor = b2Vec2(x: ax, y: ay)
        var def = b2DefaultRevoluteJointDef()
        def.bodyIdA = ba
        def.bodyIdB = bb
        def.localAnchorA = b2Body_GetLocalPoint(ba, anchor)
        def.localAnchorB = b2Body_GetLocalPoint(bb, anchor)
        def.referenceAngle = relativeAngle(ba, bb)
        def.enableLimit = enableLimits
        def.lowerAngle = lower
        def.upperAngle = upper
        def.maxMotorTorque = frictionTorque
        def.motorSpeed = motorSpeed
        def.enableMotor = motorSpeed != 0 || frictionTorque != 0
        return storeJoint(b2CreateRevoluteJoint(w, &def))
    }

    private static func distanceDef(_ ba: b2BodyId, _ bb: b2BodyId,
                                    _ ax: Float, _ ay: Float, _ bx: Float, _ by: Float) -> b2DistanceJointDef {
        var def = b2DefaultDistanceJointDef()
        def.bodyIdA = ba
        def.bodyIdB = bb
        def.localAnchorA = b2Body_GetLocalPoint(ba, b2Vec2(x: ax, y: ay))
        def.localAnchorB = b2Body_GetLocalPoint(bb, b2Vec2(x: bx, y: by))
        let dx = bx - ax
        let dy = by - ay
        def.length = (dx * dx + dy * dy).squareRoot()
        return def
    }

    static func addJointSpring(_ a: Int32, _ b: Int32, _ ax: Float, _ ay: Float,
                               _ bx: Float, _ by: Float, _ frequency: Float, _ damping: Float) -> Int32 {
        guard let w = world, let ba = body(a), let bb = body(b) else { return -1 }
        var def = distanceDef(ba, bb, ax, ay, bx, by)
        def.enableSpring = true
        def.hertz = frequency
        def.dampingRatio = damping
        return storeJoint(b2CreateDistanceJoint(w, &def))
    }

    static func addJointSliding(_ a: Int32, _ b: Int32, _ ax: Float, _ ay: Float,
                                _ dx: Float, _ dy: Float,
                                enableLimits: Bool, _ lower: Float, _ upper: Float) -> Int32 {
        guard let w = world, let ba = body(a), let bb = body(b) else { return -1 }
        let anchor = b2Vec2(x: ax, y: ay)
        var def = b2DefaultPrismaticJointDef()
        def.bodyIdA = ba
        def.bodyIdB = bb
        def.localAnchorA = b2Body_GetLocalPoint(ba, anchor)
        def.localAnchorB = b2Body_GetLocalPoint(bb, anchor)
        def.localAxisA = b2Body_GetLocalVector(ba, b2Vec2(x: dx, y: dy))
        def.referenceAngle = relativeAngle(ba, bb)
        def.enableLimit = enableLimits
        def.lowerTranslation = lower
        def.upperTranslation = upper
        return storeJoint(b2CreatePrismaticJoint(w, &def))
    }

    // Rope-style limit: free within the limit, rigid at the bound. A zero-hertz
    // spring removes the rigid-length constraint while the limit clamps.
    static func addJointLimit(_ a: Int32, _ b: Int32, _ ax: Float, _ ay: Float,
                              _ bx: Float, _ by: Float, _ maxLength: Float) -> Int32 {
        guard let w = world, let ba = body(a), let bb = body(b) else { return -1 }
        var def = distanceDef(ba, bb, ax, ay, bx, by)
        def.enableSpring = true
        def.hertz = 0
        def.dampingRatio = 0
        def.enableLimit = true
        def.minLength = 0
        def.maxLength = maxLength
        if def.length > maxLength { def.length = maxLength }
        return storeJoint(b2CreateDistanceJoint(w, &def))
    }

    static func addJointFixed(_ a: Int32, _ b: Int32, _ ax: Float, _ ay: Float) -> Int32 {
        guard let w = world, let ba = body(a), let bb = body(b) else { return -1 }
        let anchor = b2Vec2(x: ax, y: ay)
        var def = b2DefaultWeldJointDef()
        def.bodyIdA = ba
        def.bodyIdB = bb
        def.localAnchorA = b2Body_GetLocalPoint(ba, anchor)
        def.localAnchorB = b2Body_GetLocalPoint(bb, anchor)
        def.referenceAngle = relativeAngle(ba, bb)
        return storeJoint(b2CreateWeldJoint(w, &def))
    }

    static func addJointDistance(_ a: Int32, _ b: Int32, _ ax: Float, _ ay: Float,
                                 _ bx: Float, _ by: Float) -> Int32 {
        guard let w = world, let ba = body(a), let bb = body(b) else { return -1 }
        var def = distanceDef(ba, bb, ax, ay, bx, by)
        return storeJoint(b2CreateDistanceJoint(w, &def))
    }

    // MARK: - Contact events

    // Snapshot the step's begin-touch events (contact pairs for solid bodies,
    // sensor pairs for contact-only bodies) BEFORE delivery: didBegin handlers
    // destroy bodies (pellet eaten -> removeFromParent), which would invalidate
    // the shape ids the remaining events still reference. A sensor overlap is
    // reported from each sensor's side, so symmetric pairs are deduped to keep
    // Apple's one-didBegin-per-pair contract.
    static func drainBeginContacts() -> [BeginContact] {
        guard let w = world else { return [] }
        var out = [BeginContact]()
        var seen = Set<UInt64>()

        func record(_ shapeA: b2ShapeId, _ shapeB: b2ShapeId) {
            let bodyA = b2Shape_GetBody(shapeA)
            let bodyB = b2Shape_GetBody(shapeB)
            let idA = Int32(Int(bitPattern: b2Body_GetUserData(bodyA)) - 1)
            let idB = Int32(Int(bitPattern: b2Body_GetUserData(bodyB)) - 1)
            guard idA >= 0, idB >= 0 else { return }
            let lo = UInt64(UInt32(bitPattern: min(idA, idB)))
            let hi = UInt64(UInt32(bitPattern: max(idA, idB)))
            let key = (hi << 32) | lo
            if seen.contains(key) { return }
            seen.insert(key)
            out.append(BeginContact(
                catA: UInt32(truncatingIfNeeded: b2Shape_GetFilter(shapeA).categoryBits),
                catB: UInt32(truncatingIfNeeded: b2Shape_GetFilter(shapeB).categoryBits),
                bodyA: idA, bodyB: idB))
        }

        let ce = b2World_GetContactEvents(w)
        for i in 0..<Int(ce.beginCount) {
            let e = ce.beginEvents[i]
            record(e.shapeIdA, e.shapeIdB)
        }
        let se = b2World_GetSensorEvents(w)
        for i in 0..<Int(se.beginCount) {
            let e = se.beginEvents[i]
            record(e.sensorShapeId, e.visitorShapeId)
        }
        return out
    }
}
