import simd

/// The camera WE's volumetrics see: the scene camera's view and projection (ctx+0x930), in the
/// depth convention the volumetric shaders assume (clip z from 0 at the near plane to 1 at the
/// far one, D3D's), right-handed as WE's light views are.
///
/// - **Orthographic scenes** (0x140183e1b…0x140183e95): `ortho(0, width, 0, height)` with near
///   −2000 and far 2000, whatever `nearz`/`farz` say.
/// - **Perspective scenes**: `SceneCamera`'s field of view, near and far planes.
///
/// The view is `lookAt(eye, center, up)` of scene.json's `camera` [?: the orthographic eye's x and
/// y weren't traced; the library's 2D scenes all author (0, 0, 1)]. Camera shake and parallax
/// don't move it yet.
struct SceneVolumetricsCamera: Equatable {
    enum Projection: Equatable {
        case orthographic(width: Float, height: Float)
        case perspective(fieldOfViewDegrees: Float, near: Float, far: Float)
    }

    var eye = SIMD3<Float>(0, 0, 1)
    var center = SIMD3<Float>(0, 0, 0)
    var up = SIMD3<Float>(0, 1, 0)
    var projection = Projection.orthographic(width: 1920, height: 1080)

    static let orthographicDepth: Float = 2000

    init(eye: SIMD3<Float> = SIMD3(0, 0, 1), center: SIMD3<Float> = .zero, up: SIMD3<Float> = SIMD3(0, 1, 0),
         projection: Projection = .orthographic(width: 1920, height: 1080)) {
        self.eye = eye
        self.center = center
        self.up = up
        self.projection = projection
    }

    init(scene: WEScene, size: SIMD2<Float>) {
        if let camera = SceneCamera(scene: scene) {
            self.init(eye: camera.eye, center: camera.center, up: camera.up,
                      projection: .perspective(fieldOfViewDegrees: camera.fieldOfView,
                                               near: camera.nearPlane, far: camera.farPlane))
        } else {
            func vector(_ text: String?, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
                guard let text else { return fallback }
                let parsed = text.parseVector3()
                return SIMD3(Float(parsed.0), Float(parsed.1), Float(parsed.2))
            }
            self.init(eye: vector(scene.camera.eye, SIMD3(0, 0, 1)), center: vector(scene.camera.center, .zero),
                      up: vector(scene.camera.up, SIMD3(0, 1, 0)),
                      projection: .orthographic(width: size.x, height: size.y))
        }
    }

    var isOrthographic: Bool {
        if case .orthographic = projection { return true }
        return false
    }

    /// The view direction (ctx+0x160).
    var forward: SIMD3<Float> { simd_normalize(center - eye) }

    func view() -> simd_float4x4 {
        SceneVolumetricLight.lookAt(eye: eye, forward: forward, up: up)
    }

    /// `aspect` is the render target's width over height (perspective scenes only).
    func viewProjection(aspect: Float) -> simd_float4x4 {
        let projectionMatrix: simd_float4x4
        switch projection {
        case let .orthographic(width, height):
            projectionMatrix = Self.orthographic(left: 0, right: width, bottom: 0, top: height,
                                                 near: -Self.orthographicDepth, far: Self.orthographicDepth)
        case let .perspective(fieldOfView, near, far):
            projectionMatrix = SceneVolumetricLight.perspective(fieldOfView: fieldOfView * .pi / 180, aspect: aspect,
                                                                near: near, far: far)
        }
        return projectionMatrix * view()
    }

    /// Right-handed, depth 0…1 (the device's ortho, vt+0x18).
    static func orthographic(left: Float, right: Float, bottom: Float, top: Float,
                             near: Float, far: Float) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(2 / (right - left), 0, 0, 0),
            SIMD4(0, 2 / (top - bottom), 0, 0),
            SIMD4(0, 0, 1 / (near - far), 0),
            SIMD4(-(right + left) / (right - left), -(top + bottom) / (top - bottom), near / (near - far), 1)))
    }
}

/// One light's volume in one frame (`wallpaper64.exe` 0x140196ce0; docs/lighting-plan.md §2.8):
/// where its mesh goes, what the volumetric shaders read about it, and whether the camera is inside.
struct SceneVolumetricLight: Equatable {
    var shape: SceneVolumeMesh.Shape
    /// `g_AltModelMatrix` (ctx+0xa70): the light's projection (+0x338), world to light clip space.
    var lightProjection: simd_float4x4
    /// `g_AltViewProjectionMatrix` (ctx+0xab0): the mesh into the world.
    var volume: simd_float4x4
    /// `g_RenderVar0…4`.
    var renderVars: [SIMD4<Float>]
    /// The camera is inside the volume: `volumetrics_fullscreen` draws it (0x140198536).
    var cameraInside: Bool

    /// The spot's clip volume is a box when it has a cookie or a shadow (0x140185940), else a cone.
    static func shape(of light: SceneLight) -> SceneVolumeMesh.Shape {
        switch light.kind {
        case .point: return .sphere
        default: return light.useCookie || light.castShadow ? .box : .cone
        }
    }

    init(light: SceneLight, world: simd_float4x4, camera: SceneVolumetricsCamera) {
        shape = Self.shape(of: light)
        let position = SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
        let forward = SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z)
        let color = light.color
        // 0x140198716…0x1401987f5. The shadow transform (+0x310) and a point's projection info
        // (+0x320) only feed SHADOW, which needs the shadow atlas (D2): zero until then.
        var var3 = SIMD4<Float>.zero
        if light.kind == .point {
            lightProjection = matrix_identity_float4x4
            // A unit sphere scaled by the radius at the light's position (0x1401985d0) [?: whether
            // WE keeps the light's rotation there wasn't traced; a sphere doesn't show it].
            volume = simd_float4x4(diagonal: SIMD4(light.radius, light.radius, light.radius, 1))
            volume.columns.3 = SIMD4(position, 1)
        } else {
            lightProjection = Self.spotProjection(light: light, world: world, orthographic: camera.isOrthographic)
            volume = lightProjection.inverse
            // WE's row 0 of the world matrix as it stands, scale included (0x1401985b3).
            var3 = SIMD4(forward, 0)
        }
        renderVars = [
            .zero,
            SIMD4(light.radius * 0.99, cos(light.innerCone * .pi / 180), cos(light.outerCone * .pi / 180), light.intensity),
            SIMD4(position, light.density),
            var3,
            SIMD4(color, light.volumetricsExponent),
        ]
        cameraInside = Self.cameraInside(shape: shape, light: light, position: position, forward: forward,
                                         lightProjection: lightProjection, camera: camera)
    }

    /// A spot's projection (+0x338, 0x14025d420): a view down the light's local +X with local +Y
    /// up, then a square perspective of twice the outer cone, from 0.05 (1 in an orthographic
    /// scene) to the radius.
    static func spotProjection(light: SceneLight, world: simd_float4x4, orthographic: Bool) -> simd_float4x4 {
        let near: Float = orthographic ? 1 : 0.05
        let far = max(light.radius, near + 0.01)
        let axis = { (column: SIMD4<Float>) in SIMD3(column.x, column.y, column.z) }
        let position = axis(world.columns.3)
        let view = lookAt(eye: position, forward: axis(world.columns.0), up: axis(world.columns.1))
        return perspective(fieldOfView: 2 * light.outerCone * .pi / 180, aspect: 1, near: near, far: far) * view
    }

    /// Right-handed: the view looks down −z. WE's light view (0x14025d4b3…0x14025d8d3) normalises
    /// the world's axes: +x is the light's local +Z, +y its +Y, −z its +X.
    static func lookAt(eye: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(forward)
        let right = simd_normalize(simd_cross(f, up))
        let trueUp = simd_cross(right, f)
        return simd_float4x4(rows: [
            SIMD4(right, -simd_dot(right, eye)),
            SIMD4(trueUp, -simd_dot(trueUp, eye)),
            SIMD4(-f, simd_dot(f, eye)),
            SIMD4(0, 0, 0, 1),
        ])
    }

    /// Right-handed, depth 0…1 (the device's perspective, vt+0x10).
    static func perspective(fieldOfView: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fieldOfView / 2)
        let x = y / max(aspect, 0.0001)
        let z = far / (near - far)
        return simd_float4x4(columns: (SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
    }

    /// WE's test for the camera inside the volume (0x1401979c3…0x1401980e5), at a point just in
    /// front of the eye.
    static func cameraInside(shape: SceneVolumeMesh.Shape, light: SceneLight, position: SIMD3<Float>,
                             forward: SIMD3<Float>, lightProjection: simd_float4x4,
                             camera: SceneVolumetricsCamera) -> Bool {
        switch shape {
        case .box:
            // 0.1 ahead, inside all six planes of the light's frustum (0x1401849e0).
            let clip = lightProjection * SIMD4(camera.eye + 0.1 * camera.forward, 1)
            return clip.w + clip.x >= 0 && clip.w - clip.x >= 0 && clip.w + clip.y >= 0 && clip.w - clip.y >= 0
                && clip.z >= 0 && clip.w - clip.z >= 0
        case .cone:
            // 0.2 ahead: past the apex, before the radius, and within the cone's radius there,
            // which is the far plane's (the distance between the unprojected far centre and far
            // top edge) scaled by the distance over the radius.
            let delta = camera.eye + 0.2 * camera.forward - position
            let direction = simd_normalize(forward)
            let along = simd_dot(direction, delta)
            let across = simd_length(delta - direction * along)
            let inverse = lightProjection.inverse
            let unproject = { (clip: SIMD4<Float>) -> SIMD3<Float> in
                let world = inverse * clip
                return SIMD3(world.x, world.y, world.z) / world.w
            }
            let farRadius = simd_distance(unproject(SIMD4(0, 1, SceneVolumeMesh.farDepth, 1)),
                                          unproject(SIMD4(0, 0, SceneVolumeMesh.farDepth, 1)))
            return along > 0 && light.radius >= along && along / light.radius * farRadius >= across
        case .sphere:
            let delta = camera.eye + 0.2 * camera.forward - position
            return light.radius * light.radius > simd_length_squared(delta)
        }
    }
}
