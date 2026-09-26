import simd

/// A 2D affine transform in WE scene space: y-up, (0,0) at the bottom-left.
struct SceneAffineTransform: Equatable {
    var linear: simd_float2x2
    var translation: SIMD2<Float>

    static let identity = SceneAffineTransform(linear: matrix_identity_float2x2, translation: .zero)

    init(linear: simd_float2x2, translation: SIMD2<Float>) {
        self.linear = linear
        self.translation = translation
    }

    /// `translate(origin) · rotate(angles) · scale(scale)`, the order WE applies an object's own
    /// `origin`, `angles` and `scale`. A positive `angles.z` turns counter-clockwise on screen (+x
    /// toward +y), as WE's object matrix does: its rotation is `Rz(z)·Ry(y)·Rx(x)` (0x1401dd630),
    /// whose +x row is (cos z, sin z). WE's previews agree (2764281221's lens flare), and so do
    /// clock scripts, which turn hands clockwise with negative angles; so does WE's editor, where
    /// z = +30 turns an object counter-clockwise.
    ///
    /// `angles.x` and `.y` tilt the object out of the plane, and the scene is drawn orthographically,
    /// so what shows is the matrix's x and y rows without their z: `angles.x` squashes it vertically
    /// by cos x and `angles.y` horizontally by cos y, with no perspective (WE's editor, 2.8.0.42).
    init(_ local: SceneLocalTransform) {
        let scale = simd_float2x2(diagonal: local.scale)
        self.init(linear: Self.rotation(angle: local.angle, tilt: local.tilt) * scale, translation: local.origin)
    }

    /// The x and y of `Rz(z)·Ry(y)·Rx(x)`'s images of +x and +y, as 0x1401dd630 builds its rows:
    /// +x → (cy·cz, cy·sz), +y → (sx·sy·cz − cx·sz, sx·sy·sz + cx·cz).
    static func rotation(angle: Float, tilt: SIMD2<Float>) -> simd_float2x2 {
        let cz = cos(angle), sz = sin(angle)
        guard tilt != .zero else { return simd_float2x2(columns: (SIMD2(cz, sz), SIMD2(-sz, cz))) }
        let cx = cos(tilt.x), sx = sin(tilt.x), cy = cos(tilt.y), sy = sin(tilt.y)
        return simd_float2x2(columns: (SIMD2(cy * cz, cy * sz),
                                       SIMD2(sx * sy * cz - cx * sz, sx * sy * sz + cx * cz)))
    }

    /// `lhs` applied after `rhs`: a parent's world transform times a child's local one.
    static func * (lhs: SceneAffineTransform, rhs: SceneAffineTransform) -> SceneAffineTransform {
        SceneAffineTransform(linear: lhs.linear * rhs.linear,
                             translation: lhs.linear * rhs.translation + lhs.translation)
    }

    func apply(_ point: SIMD2<Float>) -> SIMD2<Float> { linear * point + translation }

    /// The transform undoing this one; nil when it collapses an axis (a zero scale).
    var inverse: SceneAffineTransform? {
        let determinant = simd_determinant(linear)
        guard determinant.isFinite, abs(determinant) > 1e-12 else { return nil }
        let inverted = linear.inverse
        return SceneAffineTransform(linear: inverted, translation: -(inverted * translation))
    }

    /// How much one local unit grows along each local axis.
    var axisScale: SIMD2<Float> { SIMD2(simd_length(linear.columns.0), simd_length(linear.columns.1)) }
}

/// An object's own transform relative to its parent.
struct SceneLocalTransform: Equatable {
    var origin: SIMD2<Float>
    var scale: SIMD2<Float>
    /// `angles.z`, in radians.
    var angle: Float
    /// `angles.x` and `angles.y`, in radians: the tilt out of the scene's plane.
    var tilt: SIMD2<Float> = .zero

    static let identity = SceneLocalTransform(origin: .zero, scale: SIMD2(repeating: 1), angle: 0)

    /// The authored transform. A root object without an `origin` sits at the scene centre; a
    /// child without one sits on its parent's origin.
    init(object: WESceneObject, sceneSize: SIMD2<Float>) {
        if let origin = object.origin?.parseVector3() {
            self.origin = SIMD2(Float(origin.0), Float(origin.1))
        } else {
            self.origin = object.parent == nil ? sceneSize / 2 : .zero
        }
        let scale = object.scale?.parseVector3() ?? (1, 1, 1)
        self.scale = SIMD2(Float(scale.0), Float(scale.1))
        let angles = object.angles?.parseVector3() ?? (0, 0, 0)
        self.angle = Float(angles.2)
        self.tilt = SIMD2(Float(angles.0), Float(angles.1))
    }

    init(origin: SIMD2<Float>, scale: SIMD2<Float>, angle: Float, tilt: SIMD2<Float> = .zero) {
        self.origin = origin
        self.scale = scale
        self.angle = angle
        self.tilt = tilt
    }
}

/// Where a quad sits relative to its object's origin.
enum SceneAlignment {
    /// Offset from the origin to the quad's centre, in the object's unscaled local space.
    /// `left` puts the quad's left edge on the origin (centre.x = +w/2), `top` its top edge
    /// (centre.y = −h/2); `topleft`, `bottomright`… combine both. `center` or nil is no offset.
    static func centerOffset(_ alignment: String?, size: SIMD2<Float>) -> SIMD2<Float> {
        guard let alignment = alignment?.lowercased() else { return .zero }
        var offset = SIMD2<Float>.zero
        if alignment.contains("left") { offset.x = size.x / 2 } else if alignment.contains("right") { offset.x = -size.x / 2 }
        if alignment.contains("top") { offset.y = -size.y / 2 } else if alignment.contains("bottom") { offset.y = size.y / 2 }
        return offset
    }

    /// A text object's `horizontalalign`/`verticalalign` as one alignment: which edge of the
    /// text block sits on the origin.
    static func text(horizontal: String?, vertical: String?) -> String {
        let vertical = ["top", "bottom"].contains(vertical?.lowercased() ?? "") ? vertical!.lowercased() : ""
        let horizontal = ["left", "right"].contains(horizontal?.lowercased() ?? "") ? horizontal!.lowercased() : ""
        let combined = vertical + horizontal
        return combined.isEmpty ? "center" : combined
    }
}

/// A layer's quad in scene space: its centre and the full-extent vectors along its local x and
/// y axes (y-up), so parent rotation and non-uniform scale survive into the draw.
struct SceneQuadGeometry: Equatable {
    var center: SIMD2<Float>
    var axisX: SIMD2<Float>
    var axisY: SIMD2<Float>

    init(center: SIMD2<Float>, axisX: SIMD2<Float>, axisY: SIMD2<Float>) {
        self.center = center
        self.axisX = axisX
        self.axisY = axisY
    }

    init(world: SceneAffineTransform, size: SIMD2<Float>, alignment: String?) {
        center = world.apply(SceneAlignment.centerOffset(alignment, size: size))
        axisX = world.linear * SIMD2(size.x, 0)
        axisY = world.linear * SIMD2(0, size.y)
    }

    /// Axis-aligned extent, for code that only needs a rough footprint.
    var extent: SIMD2<Float> { SIMD2(simd_length(axisX), simd_length(axisY)) }

    /// Where the quad lies in a y-down texture of the whole scene (the scene snapshot): the UV of
    /// its top-left corner and the UV steps along its local +x (rightwards) and down its local
    /// y. Sampling with these per vertex reads exactly the scene under the quad, rotated,
    /// sheared or partly off-screen, rather than an axis-aligned box stretched over it.
    func snapshotUV(sceneSize: SIMD2<Float>) -> (origin: SIMD2<Float>, axisX: SIMD2<Float>, axisY: SIMD2<Float>) {
        let size = simd_max(sceneSize, SIMD2(1, 1))
        func uv(_ point: SIMD2<Float>) -> SIMD2<Float> { SIMD2(point.x / size.x, 1 - point.y / size.y) }
        let topLeft = center - axisX / 2 + axisY / 2
        return (uv(topLeft), SIMD2(axisX.x / size.x, -axisX.y / size.y), SIMD2(-axisY.x / size.x, axisY.y / size.y))
    }

    /// The axis-aligned box the (possibly rotated or sheared) quad covers, in scene units.
    var boundingBox: (min: SIMD2<Float>, max: SIMD2<Float>) {
        let half = (abs(axisX) + abs(axisY)) / 2
        return (center - half, center + half)
    }
}

/// The scene's parent graph. Every object has a node, including groups that draw nothing,
/// so a child's world transform can be rebuilt each frame from its ancestors'.
struct SceneTransformHierarchy {
    struct Node {
        let parentID: String?
        let local: SceneLocalTransform
        /// `parallaxDepth` x y; WE's default is 1 1 (`WESceneObject.parallaxDepthValue`).
        let parallaxDepth: SIMD2<Float>

        init(parentID: String?, local: SceneLocalTransform, parallaxDepth: SIMD2<Float> = SIMD2(1, 1)) {
            self.parentID = parentID
            self.local = local
            self.parallaxDepth = parallaxDepth
        }
    }

    private(set) var nodes: [String: Node]

    static let empty = SceneTransformHierarchy(nodes: [:])

    init(nodes: [String: Node]) { self.nodes = nodes }

    init(objects: [WESceneObject], sceneSize: SIMD2<Float>) {
        var nodes: [String: Node] = [:]
        for (index, object) in objects.enumerated() {
            let depth = object.parallaxDepthValue
            nodes[String(object.id ?? index)] = Node(parentID: object.parent.map(String.init),
                                                     local: SceneLocalTransform(object: object, sceneSize: sceneSize),
                                                     parallaxDepth: SIMD2(Float(depth.0), Float(depth.1)))
        }
        self.nodes = nodes
    }

    /// Fullscreen layers fill the scene whatever their parent is.
    mutating func makeRoot(_ id: String, local: SceneLocalTransform) {
        nodes[id] = Node(parentID: nil, local: local, parallaxDepth: nodes[id]?.parallaxDepth ?? SIMD2(1, 1))
    }

    /// `id`'s topmost ancestor, or `id` itself when it has no parent. Cycles stop the walk.
    func root(of id: String) -> String {
        var root = id
        var visited: Set<String> = [id]
        while let parentID = nodes[root]?.parentID, nodes[parentID] != nil, visited.insert(parentID).inserted {
            root = parentID
        }
        return root
    }

    /// The composed transform of `id`'s ancestors, root first. `live` supplies this frame's
    /// local transform for objects that are drawn (scripts and animations move them); other
    /// ancestors use their authored transform. Cycles stop the walk.
    func parentWorld(of id: String, live: (String) -> SceneLocalTransform? = { _ in nil }) -> SceneAffineTransform {
        var chain: [String] = []
        var visited: Set<String> = [id]
        var next = nodes[id]?.parentID
        while let parentID = next, visited.insert(parentID).inserted, let node = nodes[parentID] {
            chain.append(parentID)
            next = node.parentID
        }
        return chain.reversed().reduce(.identity) { world, ancestor in
            world * SceneAffineTransform(live(ancestor) ?? nodes[ancestor]!.local)
        }
    }

    func world(of id: String, local: SceneLocalTransform? = nil,
               live: (String) -> SceneLocalTransform? = { _ in nil }) -> SceneAffineTransform {
        guard let own = local ?? live(id) ?? nodes[id]?.local else { return .identity }
        return parentWorld(of: id, live: live) * SceneAffineTransform(own)
    }
}

/// How the composite maps scene units onto the drawable for a user placement.
enum ScenePlacementScale {
    /// Drawable pixels per scene unit. `.center` shows the scene at one *point* per unit, so a
    /// Retina drawable (`pixelsPerPoint` 2) doubles it. `.stretch` scales each axis on its own
    /// and has no single factor; callers handle it separately.
    static func scale(for placement: WallpaperPlacement, sceneSize: SIMD2<Float>, drawableSize: SIMD2<Float>,
                      pixelsPerPoint: Float) -> Float {
        let ratio = drawableSize / simd_max(sceneSize, SIMD2(1, 1))
        switch placement {
        case .fill, .zoom, .stretch: return max(ratio.x, ratio.y)
        case .fit: return min(ratio.x, ratio.y)
        case .center: return max(pixelsPerPoint, 1)
        }
    }

    /// The scene point (scene units, y up) under a drawable point (pixels, y up from the
    /// drawable's bottom-left): the inverse of the composite's placement. Outside the drawn scene
    /// (letterbox bars, cropped edges) it lies beyond the scene's bounds.
    static func scenePoint(drawablePoint: SIMD2<Float>, placement: WallpaperPlacement, sceneSize: SIMD2<Float>,
                           drawableSize: SIMD2<Float>, pixelsPerPoint: Float) -> SIMD2<Float> {
        let drawable = simd_max(drawableSize, SIMD2(1, 1))
        if placement == .stretch { return drawablePoint * sceneSize / drawable }
        let scale = self.scale(for: placement, sceneSize: sceneSize, drawableSize: drawable, pixelsPerPoint: pixelsPerPoint)
        let offset = (drawable - sceneSize * scale) / 2
        return (drawablePoint - offset) / scale
    }
}
