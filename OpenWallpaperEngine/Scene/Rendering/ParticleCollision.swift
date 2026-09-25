import simd

/// A collision operator (`collisionplane`, `collisionsphere`, `collisionquad`, `collisionbounds`),
/// as authored in the emitter's space. Only a particle's centre collides, as in WE.
struct ParticleCollision: Equatable {
    enum Shape: Equatable {
        /// Particles stay where `dot(normal, p) >= distance`.
        case plane(normal: SIMD3<Float>, distance: Float)
        /// A solid ball.
        case sphere(origin: SIMD3<Float>, radius: Float)
        /// A one-sided rectangle, hit from the side `normal` faces.
        case quad(origin: SIMD3<Float>, normal: SIMD3<Float>, forward: SIMD3<Float>, size: SIMD2<Float>)
        /// The scene's rectangle, `size` wide.
        case bounds(size: SIMD2<Float>)
    }

    /// `collisionbehavior`: bounce unless "slide", "stop" or "delete".
    enum Behavior: UInt32 {
        case bounce = 0, slide, stop, delete

        init(_ name: String?) {
            switch name?.lowercased() {
            case "slide": self = .slide
            case "stop": self = .stop
            case "delete": self = .delete
            default: self = .bounce
            }
        }
    }

    let shape: Shape
    let behavior: Behavior
    /// `bouncefactor` (default 0.5).
    let bounceFactor: Float
    /// Flag bit 0: the shape sits on this control point (its `origin` or `distance` ignored).
    let controlPoint: Int?
    /// Flag bit 1: a hit stops the particle's rotation.
    let stopsRotation: Bool

    /// The operator `element`, nil for one that isn't a collision WE resolves at runtime
    /// (`collisionbox` does nothing; `collisionmodel` needs a model).
    init?(_ element: WEParticleOperator, sceneSize: SIMD2<Float>) {
        func vector(_ value: WEFlexValue?, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
            guard let value else { return fallback }
            let v = value.vectorValue
            return SIMD3(Float(v.0), Float(v.1), Float(v.2))
        }
        switch element.name {
        case "collisionplane":
            shape = .plane(normal: vector(element.plane, SIMD3(0, 1, 0)), distance: Float(element.distance ?? -150))
        case "collisionsphere":
            shape = .sphere(origin: vector(element.origin, SIMD3(0, -200, 0)), radius: Float(element.radius ?? 50))
        case "collisionquad":
            let size = element.size?.vectorValue ?? (200, 200, 0)
            shape = .quad(origin: vector(element.origin, SIMD3(0, -150, 0)), normal: vector(element.plane, SIMD3(0, 1, 0)),
                          forward: vector(element.forward, SIMD3(0, 0, 1)), size: SIMD2(Float(size.0), Float(size.1)))
        case "collisionbounds":
            shape = .bounds(size: sceneSize)
        default:
            return nil
        }
        behavior = Behavior(element.collisionbehavior)
        bounceFactor = Float(element.bouncefactor ?? 0.5)
        let flags = element.flags ?? 0
        controlPoint = (flags & 1) != 0 ? min(max(element.controlpoint ?? 0, 0), 7) : nil
        stopsRotation = (flags & 2) != 0
    }

    init(shape: Shape, behavior: Behavior = .bounce, bounceFactor: Float = 0.5, controlPoint: Int? = nil,
         stopsRotation: Bool = false) {
        self.shape = shape
        self.behavior = behavior
        self.bounceFactor = bounceFactor
        self.controlPoint = controlPoint
        self.stopsRotation = stopsRotation
    }

    /// The shape in scene space this frame. `controlPoint` gives a control point's position.
    func placed(in space: SceneParticleEmitterSpace, controlPoint position: (Int) -> SIMD2<Float>) -> [ParticleCollisionPlacement] {
        let scale = sqrt(abs(simd_determinant(space.world.linear)))
        let response = SIMD4<Float>(-(1 + bounceFactor), Float(behavior.rawValue), stopsRotation ? 1 : 0, 0)
        func direction(_ v: SIMD3<Float>) -> SIMD2<Float>? {
            let turned = space.rotation * SIMD2(v.x, v.y)
            return simd_length(turned) > 1e-6 ? simd_normalize(turned) : nil
        }
        let anchor = controlPoint.map(position)
        switch shape {
        case .plane(let normal, let distance):
            guard let n = direction(normal) else { return [] }
            let d = anchor.map { simd_dot(n, $0) } ?? distance * scale + simd_dot(n, space.origin)
            return [ParticleCollisionPlacement(kind: .plane, shape: SIMD4(n.x, n.y, d, 0), response: response)]
        case .sphere(let origin, let radius):
            let center = anchor ?? space.world.apply(SIMD2(origin.x, origin.y))
            return [ParticleCollisionPlacement(kind: .sphere, shape: SIMD4(center.x, center.y, radius * scale, 0),
                                               response: response)]
        case .quad(let origin, let normal, let forward, let size):
            // WE's axes: right = normal × forward spans size.x, normal × … size.y (along z in 2D).
            let right3 = simd_cross(normal, forward)
            guard let n = direction(normal), let right = direction(right3) else { return [] }
            let up3 = simd_cross(simd_normalize(right3), simd_normalize(normal))
            let center = anchor ?? space.world.apply(SIMD2(origin.x, origin.y))
            let halfUp = simd_length(SIMD2(up3.x, up3.y)) > 1e-6 ? size.y / 2 * scale : .infinity
            let up = direction(up3) ?? .zero
            return [ParticleCollisionPlacement(kind: .quad, shape: SIMD4(center.x, center.y, n.x, n.y),
                                               axis: SIMD4(right.x, right.y, size.x / 2 * scale, halfUp),
                                               extra: SIMD4(up.x, up.y, 0, 0), response: response)]
        case .bounds(let size):
            // Keeps particles inside the scene.
            let planes: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(-1, 0, -size.x), SIMD3(0, -1, -size.y)]
            return planes.map {
                ParticleCollisionPlacement(kind: .plane, shape: SIMD4($0.x, $0.y, $0.z, 0),
                                           extra: SIMD4(0, 0, 1, 0), response: response)
            }
        }
    }
}

/// A collision shape in scene space for one step (`ParticleCollision.placed`); the GPU reads the
/// same layout (`ParticleShared.h`).
struct ParticleCollisionPlacement: Equatable {
    enum Kind: UInt32 { case plane = 0, sphere, quad }

    /// Plane: normal xy, distance. Sphere: centre xy, radius. Quad: centre xy, normal xy.
    var shape: SIMD4<Float>
    /// Quad: right axis xy, half size along it, half size along `extra`.
    var axis = SIMD4<Float>.zero
    /// Quad: second axis xy. z: 1 when the shape is fixed in the scene (bounds), so an instance
    /// of an instanced system doesn't carry it (`moved(by:)`).
    var extra = SIMD4<Float>.zero
    /// Bounce coefficient −(1 + bouncefactor), behaviour, stops rotation, kind.
    var response: SIMD4<Float>

    init(kind: Kind, shape: SIMD4<Float>, axis: SIMD4<Float> = .zero, extra: SIMD4<Float> = .zero,
         response: SIMD4<Float>) {
        self.shape = shape
        self.axis = axis
        self.extra = extra
        self.response = SIMD4(response.x, response.y, response.z, Float(kind.rawValue))
    }

    var kind: Kind { Kind(rawValue: UInt32(response.w)) ?? .plane }

    /// The shape carried by `translation` (an instance's position).
    func moved(by translation: SIMD2<Float>) -> ParticleCollisionPlacement {
        guard extra.z < 0.5 else { return self }
        var moved = self
        switch kind {
        case .plane: moved.shape.z += simd_dot(SIMD2(shape.x, shape.y), translation)
        case .sphere, .quad:
            moved.shape.x += translation.x
            moved.shape.y += translation.y
        }
        return moved
    }

    /// Resolves a particle that moved from `previous` to `position` against this shape.
    func resolve(position: inout SIMD2<Float>, velocity: inout SIMD2<Float>, angularVelocity: inout Float,
                 dies: inout Bool, previous: SIMD2<Float>) {
        var normal = SIMD2<Float>.zero
        switch kind {
        case .plane:
            let n = SIMD2(shape.x, shape.y)
            let depth = simd_dot(n, position) - shape.z
            guard depth < 0 else { return }
            position -= n * depth
            normal = n
        case .sphere:
            let center = SIMD2(shape.x, shape.y)
            let offset = position - center
            let distance = simd_length(offset)
            guard distance < shape.z else { return }
            normal = distance > 1e-6 ? offset / distance : SIMD2(0, 1)
            position = center + normal * shape.z
        case .quad:
            let center = SIMD2(shape.x, shape.y), n = SIMD2(shape.z, shape.w)
            let depth = simd_dot(n, position - center)
            guard depth <= 0, simd_dot(n, previous - center) > 0,
                  abs(simd_dot(position - center, SIMD2(axis.x, axis.y))) < axis.z,
                  abs(simd_dot(position - center, SIMD2(extra.x, extra.y))) < axis.w else { return }
            position -= n * depth * 1.05
            normal = n
        }
        switch ParticleCollision.Behavior(rawValue: UInt32(response.y)) ?? .bounce {
        case .bounce: velocity += normal * simd_dot(normal, velocity) * response.x
        case .slide: velocity -= normal * simd_dot(normal, velocity)
        case .stop: velocity = .zero
        case .delete: dies = true
        }
        if response.z > 0.5 { angularVelocity = 0 }
    }
}
