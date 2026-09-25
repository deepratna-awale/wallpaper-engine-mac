import Foundation
import simd

/// A particle system's material, resolved at load for Wallpaper Engine's own particle shaders
/// (`genericparticle`, `genericropeparticle` or a workshop shader in their place).
struct ParticleMaterialPlan {
    /// One way to run the material's shader. The renderer uses the first stage whose pipeline
    /// builds; when none does, the system keeps the built-in particle draw.
    struct Stage {
        enum Geometry: Equatable {
            /// The `.geom` stage folded into the vertex stage (`GeometryShaderEmulation`): one
            /// instance per record, `vertexCount` vertices each, as a triangle list.
            case emulated(vertexCount: Int)
            /// WE's no-geometry-shader stream (`GS_ENABLED` 0): each record expanded on the GPU to
            /// four vertices, drawn as two triangles.
            case expandedQuads
        }

        let geometry: Geometry
        let variant: TranslatedShaderVariant
        /// Identifies the variant (`ShaderVariantTranslator.cacheKey`).
        let variantKey: String
        let textures: [Int: SceneEffectTextureInput]
        let constants: ShaderConstantResolver.ResolvedConstants

        /// Reads `_rt_FullFrameBuffer` (refraction).
        var readsSceneSnapshot: Bool {
            textures.values.contains { if case .sceneSnapshot = $0 { return true } else { return false } }
        }
    }

    /// The material JSON, for logs.
    let materialPath: String
    /// The shader actually used (the rope renderers swap in `genericropeparticle`).
    let shader: String
    let format: ParticleVertexFormat
    /// Material blending (`translucent`, `additive`, `normal`…).
    let blending: String
    let stages: [Stage]
    /// `g_RenderVar0` of sprite trails: `(length, maxlength, minlength, 0)`.
    let trailLengths: SIMD4<Float>
    /// Set when texture 0 is a sprite sheet (`SPRITESHEET`).
    let spriteSheet: SpriteSheet?
}
