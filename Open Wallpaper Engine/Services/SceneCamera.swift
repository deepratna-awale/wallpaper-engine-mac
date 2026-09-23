import Foundation
import simd

/// The camera for a perspective scene.
///
/// Wallpaper Engine scenes come in two flavours. Most declare `orthogonalprojection`, place objects
/// in pixels and are drawn flat. A minority omit it and are true 3D: objects carry world-space
/// coordinates (typically single digits rather than hundreds), `general` supplies `fov`/`nearz`/
/// `farz`, and `camera` supplies an eye/center/up basis. Those scenes need a real view-projection
/// matrix or every object collapses into the top-left corner at sub-pixel size.
struct SceneCamera {
    let eye: SIMD3<Float>
    let center: SIMD3<Float>
    let up: SIMD3<Float>
    let fieldOfView: Float
    let nearPlane: Float
    let farPlane: Float

    /// `nil` for orthographic scenes, which keep the existing pixel-space path.
    init?(scene: WEScene) {
        guard scene.general.orthogonalprojection == nil else { return nil }
        let eye = (scene.camera.eye ?? "0 0 1").parseVector3()
        let center = (scene.camera.center ?? "0 0 0").parseVector3()
        let up = (scene.camera.up ?? "0 1 0").parseVector3()
        self.eye = SIMD3<Float>(Float(eye.0), Float(eye.1), Float(eye.2))
        self.center = SIMD3<Float>(Float(center.0), Float(center.1), Float(center.2))
        self.up = SIMD3<Float>(Float(up.0), Float(up.1), Float(up.2))
        // Zoom scales the vertical field of view the same way Wallpaper Engine's editor does.
        let zoom = Float(scene.general.zoom ?? 1)
        self.fieldOfView = Float(scene.general.fov ?? 50) / max(zoom, 0.0001)
        self.nearPlane = Float(scene.general.nearz ?? 0.01)
        self.farPlane = Float(scene.general.farz ?? 10000)
    }

    func viewProjection(aspectRatio: Float) -> simd_float4x4 {
        Self.perspective(fieldOfViewDegrees: fieldOfView, aspectRatio: aspectRatio,
                         near: nearPlane, far: farPlane) * lookAt()
    }

    private func lookAt() -> simd_float4x4 {
        let forward = simd_normalize(center - eye)
        let right = simd_normalize(simd_cross(forward, up))
        let trueUp = simd_cross(right, forward)
        return simd_float4x4(columns: (
            SIMD4<Float>(right.x, trueUp.x, -forward.x, 0),
            SIMD4<Float>(right.y, trueUp.y, -forward.y, 0),
            SIMD4<Float>(right.z, trueUp.z, -forward.z, 0),
            SIMD4<Float>(-simd_dot(right, eye), -simd_dot(trueUp, eye), simd_dot(forward, eye), 1)
        ))
    }

    /// Metal clip space runs z from 0 to 1, unlike OpenGL's -1 to 1.
    private static func perspective(fieldOfViewDegrees: Float, aspectRatio: Float,
                                    near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fieldOfViewDegrees * .pi / 360)
        let x = y / max(aspectRatio, 0.0001)
        let z = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)
        ))
    }
}
