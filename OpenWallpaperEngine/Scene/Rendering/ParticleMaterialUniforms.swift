import Foundation
import simd

/// The particle-specific uniforms of WE's particle shaders for one system and frame: matrices,
/// the orthographic view, `g_Orientation*` and `g_RenderVar0/1`.
struct ParticleMaterialUniforms {
    /// Scene units (y up) to clip space. The translated vertex stage flips y (GL rows), so the
    /// top of the scene maps to GL's bottom.
    let modelViewProjection: simd_float4x4
    let renderVars: [Int: SIMD4<Float>]
    let eyePosition: SIMD3<Float>
    /// `g_OrientationRight` and `g_OrientationUp`: the renderer's orientation (`ParticleOrientation`;
    /// by default the scene camera's axes, 2D scenes look down −z with y up) through the emitter's
    /// scale and rotation (`ParticleSystemRuntime.drawLinear`). WE expands a sprite along them in the
    /// system's own space and draws it through the system's model matrix; the particles here are in
    /// scene space, so the axes carry it.
    let orientationRight: SIMD3<Float>
    let orientationUp: SIMD3<Float>
    /// `g_OrientationForward`: the renderer's (`ParticleOrientation`); (0, 0, 1) facing the camera.
    let orientationForward: SIMD3<Float>

    /// The scene camera's axes, as WE binds them to particles.
    static let orientationRight = SIMD3<Float>(1, 0, 0)
    /// How far in front of the scene the eye sits. The view is orthographic, so view rays are
    /// parallel; a distant eye keeps the shaders' eye-to-particle directions (trail and rope
    /// facing) parallel to them too.
    static let eyeDistance: Float = 100_000

    init(plan: ParticleMaterialPlan, system: ParticleSystemRuntime, sceneSize: SIMD2<Float>,
         texture0: BuiltinTextureInfo?) {
        let size = simd_max(sceneSize, SIMD2(1, 1))
        modelViewProjection = PassMatrices.ortho(left: 0, right: size.x, bottom: size.y, top: 0)
        eyePosition = SIMD3(size.x / 2, size.y / 2, Self.eyeDistance)
        let axes = system.configuration.orientation.axes(linear: system.drawLinear)
        orientationRight = axes.right
        orientationUp = axes.up
        orientationForward = axes.forward
        var renderVars: [Int: SIMD4<Float>] = [:]
        switch plan.format {
        case .sprite: renderVars[0] = plan.trailLengths
        case .rope: renderVars[0] = ParticleRecordWriter.ropeRenderVar(system)
        }
        renderVars[1] = Self.spriteSheetRenderVar(plan.spriteSheet, texture: texture0)
        self.renderVars = renderVars
    }

    /// `g_RenderVar1`: `(frame width, frame height, frame count, frame height / width)`, frame
    /// sizes in texture coordinates of the allocated texture; without a sheet only the texture's
    /// aspect ratio.
    static func spriteSheetRenderVar(_ sheet: SpriteSheet?, texture: BuiltinTextureInfo?) -> SIMD4<Float> {
        let allocated = simd_max(texture?.allocatedSize ?? SIMD2(1, 1), SIMD2(1, 1))
        let content = simd_max(texture?.contentSize ?? allocated, SIMD2(1, 1))
        guard let sheet, sheet.columns > 0, sheet.rows > 0, sheet.frames > 0 else {
            return SIMD4(0, 0, 0, content.y / content.x)
        }
        let columns = Float(sheet.columns), rows = Float(sheet.rows)
        let frame = SIMD2(content.x / columns, content.y / rows)
        return SIMD4(frame.x / allocated.x, frame.y / allocated.y, Float(sheet.frames), frame.y / frame.x)
    }

    /// `g_ViewUp`: the scene direction that points up in the clip space the shaders see.
    /// `modelViewProjection` puts the top of the scene at GL's bottom (the translated stage flips
    /// it back), so that is scene −y. Screen coordinates derived from the clip position
    /// (`v_ScreenCoord`) then run top-down like Metal's texture rows, and the refraction offsets
    /// that `ComputeScreenRefractionTangents` builds from this axis follow them.
    static let viewUp = SIMD3<Float>(0, -1, 0)

    /// The frame's built-ins with this system's view.
    func frame(from frame: BuiltinFrameContext) -> BuiltinFrameContext {
        var result = frame
        result.eyePosition = eyePosition
        result.viewUp = Self.viewUp
        result.viewRight = Self.orientationRight
        result.viewForward = SIMD3(0, 0, -1)
        return result
    }

    /// Writes the values `UniformProgram` doesn't: WE's particle-only uniforms, and the ones that
    /// change with the system every frame.
    func patch(_ bytes: inout [UInt8], layout: UniformLayout) {
        let values: [(String, [Float])] = [
            ("g_OrientationRight", Self.flat(orientationRight)),
            ("g_OrientationUp", Self.flat(orientationUp)),
            ("g_OrientationForward", Self.flat(orientationForward)),
            ("g_EyePosition", Self.flat(eyePosition)),
            ("g_RenderVar0", Self.flat(renderVars[0] ?? .zero)),
            ("g_RenderVar1", Self.flat(renderVars[1] ?? .zero)),
        ]
        for (name, components) in values {
            guard let member = layout.members[name] else { continue }
            UniformWriter.write(components, member: member, into: &bytes)
        }
    }

    private static func flat(_ v: SIMD3<Float>) -> [Float] { [v.x, v.y, v.z] }
    private static func flat(_ v: SIMD4<Float>) -> [Float] { [v.x, v.y, v.z, v.w] }
}
