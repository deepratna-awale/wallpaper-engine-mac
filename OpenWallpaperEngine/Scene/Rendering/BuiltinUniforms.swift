import Foundation
import simd

/// Per-frame inputs to WE's built-in uniforms (plan §2). Computed once per rendered frame.
struct BuiltinFrameContext {
    /// Seconds since the scene started, no wrap.
    ///
    /// `g_Time` is this value as a 32-bit float, like WE's ("time the program has been running in
    /// seconds"). WE never wraps it: its shaders scale it by arbitrary speeds (`g_Time * speed`,
    /// `sin(g_Time * f)`, scrolling offsets), so no wrap period is seamless for all of them and any
    /// wrap is a visible jump. Shaders that need precision after long runs reduce it themselves
    /// (`frac(g_Time * g_FlowSpeed)`, WE's fix for `shake`). Float resolution is ~8 ms after a day
    /// and ~60 ms after a week of one scene; the clock restarts whenever a scene loads.
    var time: Double = 0
    var frameTime: Double = 1.0 / 60.0
    /// `(h·60 + m) / 1440`; see `BuiltinFrameContext.daytime(at:calendar:)`.
    var daytime: Float = 0
    /// 0...1, y = 0 at the bottom. The caller maps it into the layer's UV space.
    var pointer: SIMD2<Float> = SIMD2(0.5, 0.5)
    var pointerLast: SIMD2<Float> = SIMD2(0.5, 0.5)
    /// `g_PointerState`, a `vec4` in WE's shaders. WE's shipped effects (cursorripple,
    /// fluidsimulation) read only `.z`, as the press strength of the primary button; build it
    /// with `BuiltinFrameContext.pointerState(primaryDown:)`.
    var pointerState: SIMD4<Float> = .zero
    /// `0.5 + (mouse − 0.5)·influence`, computed by the caller.
    var parallax: SIMD2<Float> = SIMD2(0.5, 0.5)
    var screenSize: SIMD2<Float> = SIMD2(1920, 1080)
    var eyePosition: SIMD3<Float> = .zero
    var viewUp: SIMD3<Float> = SIMD3(0, 1, 0)
    var viewRight: SIMD3<Float> = SIMD3(1, 0, 0)
    var viewForward: SIMD3<Float> = SIMD3(0, 0, -1)
    var audio: AudioSpectrumSnapshot = .silent
    /// This frame's scene colours and lights (`SceneFrameLighting`): `g_LightAmbientColor`,
    /// `g_LightSkylightColor`, the `LightingV1` arrays and the legacy `g_Lights*`.
    var lighting = SceneFrameLighting()

    /// `g_PointerState` for the current button state. `.x` mirrors `.z` so a shader that
    /// declares the uniform as a scalar `float` still sees the press.
    static func pointerState(primaryDown: Bool) -> SIMD4<Float> {
        let down: Float = primaryDown ? 1 : 0
        return SIMD4(down, 0, down, 0)
    }

    static func daytime(at date: Date, calendar: Calendar = .current) -> Float {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return Float((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) / 1440
    }
}

/// A sprite-sheet frame's rect in its texture's UV space, for `g_Texture<n>Rotation` and
/// `g_Texture<n>Translation` (docs/timeline-plan.md §2.7): the frame's axes and its origin.
struct BuiltinSpriteFrame: Equatable {
    /// `(axisX.x, axisX.y, axisY.x, axisY.y)`, as `BuiltinTextureInfo.spriteRotation`.
    var rotation: SIMD4<Float>
    var translation: SIMD2<Float>
}

/// Metadata of the texture bound to slot N of a pass.
struct BuiltinTextureInfo {
    /// Size of the GPU texture (power-of-two padded for WE `.tex`).
    var allocatedSize: SIMD2<Float>
    /// Size of the image inside it. Render targets use the allocated size.
    var contentSize: SIMD2<Float>
    /// Sprite-sheet frame, as LWE computes it: `(width1/W, width2/W, height2/H, height1/H)`.
    var spriteRotation: SIMD4<Float>? = nil
    /// Sprite-sheet frame origin `(x/W, y/H)`.
    var spriteTranslation: SIMD2<Float>? = nil
    var mipCount: Int = 1
}

/// Per-pass inputs to WE's built-in uniforms.
struct BuiltinPassContext {
    var targetSize: SIMD2<Float>
    var modelViewProjection: simd_float4x4 = matrix_identity_float4x4
    var modelMatrix: simd_float4x4 = matrix_identity_float4x4
    var viewMatrix: simd_float4x4 = matrix_identity_float4x4
    var viewProjection: simd_float4x4 = matrix_identity_float4x4
    /// `g_AltModelMatrix` and `g_AltViewProjectionMatrix`: the layer's own placement in the scene
    /// while a pass draws it elsewhere (WE's prelighting draw into the layer's effect buffer,
    /// docs/lighting-plan.md §2.3). nil: `modelMatrix` and `viewProjection`.
    var altModelMatrix: simd_float4x4? = nil
    var altViewProjection: simd_float4x4? = nil
    /// Identity in LWE.
    var effectTextureProjection: simd_float4x4 = matrix_identity_float4x4
    var textures: [Int: BuiltinTextureInfo] = [:]
    var color: SIMD3<Float> = SIMD3(repeating: 1)
    var alpha: Float = 1
    var userAlpha: Float = 1
    var brightness: Float = 1
    /// `g_RenderVar0...4`; zeros unless the renderer (e.g. particles) provides them.
    var renderVars: [Int: SIMD4<Float>] = [:]
}

/// Values of WE's built-in uniforms, as flat float arrays. Matrices are column-major (16 floats,
/// `g_NormalModelMatrix` 9); the uniform layout writer is responsible for std140 padding.
enum BuiltinUniforms {
    private static let fixedNames: Set<String> = [
        "g_Time", "g_Daytime", "g_DayTime", "g_Frametime", "g_PointerPosition", "g_PointerPositionLast",
        "g_PointerState", "g_ParallaxPosition", "g_TexelSize", "g_TexelSizeHalf", "g_Screen",
        "g_ModelViewProjectionMatrix", "g_ModelViewProjectionMatrixInverse",
        "g_EffectModelViewProjectionMatrix", "g_EffectModelViewProjectionMatrixInverse",
        "g_ModelMatrix", "g_ModelMatrixInverse", "g_EffectModelMatrix", "g_AltModelMatrix", "g_AltNormalModelMatrix",
        "g_ModelViewMatrix", "g_ModelViewMatrixInverse", "g_ViewProjectionMatrix",
        "g_ViewProjectionMatrixInverse", "g_AltViewProjectionMatrix", "g_ViewMatrix",
        "g_EffectTextureProjectionMatrix", "g_EffectTextureProjectionMatrixInverse", "g_NormalModelMatrix",
        "g_Color4", "g_Color", "g_Alpha", "g_UserAlpha", "g_Brightness",
        "g_EyePosition", "g_ViewUp", "g_ViewRight",
        "g_ViewForward", "g_TextureReductionScale",
    ]

    static func isBuiltin(_ name: String) -> Bool {
        fixedNames.contains(name) || SceneFrameLighting.uniformNames.contains(name) || textureUniform(name) != nil
            || audioUniform(name) != nil || renderVarIndex(name) != nil
    }

    /// The value of built-in `name`, or nil when `name` is not a built-in. `arrayCount` limits
    /// (or zero-pads) array uniforms such as the audio spectra to the shader's declared length.
    static func value(named name: String, frame: BuiltinFrameContext, pass: BuiltinPassContext,
                      arrayCount: Int? = nil) -> [Float]? {
        if let fixed = fixedValue(name, frame: frame, pass: pass) { return fixed }
        if let perElement = SceneFrameLighting.uniformComponents[name] {
            // Zero-padded or cut to the shader's array, whose length is the budget's too.
            let values = frame.lighting.arrays[name] ?? []
            let count = (arrayCount ?? 1) * perElement
            return Array((values + [Float](repeating: 0, count: max(0, count - values.count))).prefix(count))
        }
        if let (slot, suffix) = textureUniform(name) { return textureValue(suffix, info: pass.textures[slot]) }
        if let (bands, right) = audioUniform(name) {
            let values = frame.audio.values(bands: bands, right: right) ?? []
            guard let arrayCount else { return values }
            return Array((values + [Float](repeating: 0, count: max(0, arrayCount - values.count)))
                .prefix(arrayCount))
        }
        if let index = renderVarIndex(name) { return flat(pass.renderVars[index] ?? .zero) }
        return nil
    }

    // MARK: - Private

    private static func fixedValue(_ name: String, frame: BuiltinFrameContext,
                                   pass: BuiltinPassContext) -> [Float]? {
        let size = pass.targetSize
        switch name {
        case "g_Time": return [Float(frame.time)]
        case "g_Daytime", "g_DayTime": return [frame.daytime]
        case "g_Frametime": return [Float(frame.frameTime)]
        case "g_PointerPosition": return flat(frame.pointer)
        case "g_PointerPositionLast": return flat(frame.pointerLast)
        case "g_PointerState": return flat(frame.pointerState)
        case "g_ParallaxPosition": return flat(frame.parallax)
        case "g_TexelSize": return flat(1 / size)
        case "g_TexelSizeHalf": return flat(0.5 / size)
        case "g_Screen":
            let screen = frame.screenSize
            return [screen.x, screen.y, screen.x / screen.y]
        case "g_ModelViewProjectionMatrix", "g_EffectModelViewProjectionMatrix":
            return flat(pass.modelViewProjection)
        case "g_ModelViewProjectionMatrixInverse", "g_EffectModelViewProjectionMatrixInverse":
            return flat(pass.modelViewProjection.inverse)
        case "g_ModelMatrix", "g_EffectModelMatrix": return flat(pass.modelMatrix)
        case "g_AltModelMatrix": return flat(pass.altModelMatrix ?? pass.modelMatrix)
        case "g_ModelMatrixInverse": return flat(pass.modelMatrix.inverse)
        case "g_ModelViewMatrix": return flat(pass.viewMatrix * pass.modelMatrix)
        case "g_ModelViewMatrixInverse": return flat((pass.viewMatrix * pass.modelMatrix).inverse)
        case "g_ViewMatrix": return flat(pass.viewMatrix)
        case "g_ViewProjectionMatrix": return flat(pass.viewProjection)
        case "g_AltViewProjectionMatrix": return flat(pass.altViewProjection ?? pass.viewProjection)
        case "g_ViewProjectionMatrixInverse": return flat(pass.viewProjection.inverse)
        case "g_EffectTextureProjectionMatrix": return flat(pass.effectTextureProjection)
        case "g_EffectTextureProjectionMatrixInverse": return flat(pass.effectTextureProjection.inverse)
        case "g_NormalModelMatrix": return normalMatrix(pass.modelMatrix)
        case "g_AltNormalModelMatrix": return normalMatrix(pass.altModelMatrix ?? pass.modelMatrix)
        case "g_Color4": return [pass.color.x, pass.color.y, pass.color.z, pass.alpha]
        case "g_Color": return flat(pass.color)
        case "g_Alpha": return [pass.alpha]
        case "g_UserAlpha": return [pass.userAlpha]
        case "g_Brightness": return [pass.brightness]
        case "g_LightAmbientColor": return flat(frame.lighting.ambient)
        case "g_LightSkylightColor": return flat(frame.lighting.skylight)
        case "g_EyePosition": return flat(frame.eyePosition)
        case "g_ViewUp": return flat(frame.viewUp)
        case "g_ViewRight": return flat(frame.viewRight)
        case "g_ViewForward": return flat(frame.viewForward)
        case "g_TextureReductionScale": return [1]
        default: return nil
        }
    }

    /// WE's normal matrix (0x1400d8840, and 0x1400d8aab for the alt one): the model's upper 3×3
    /// with each axis normalised, not the inverse transpose. A zero axis stays zero.
    private static func normalMatrix(_ m: simd_float4x4) -> [Float] {
        [m.columns.0.xyz, m.columns.1.xyz, m.columns.2.xyz].flatMap { axis -> [Float] in
            let length = simd_length(axis)
            let unit = length > 0 ? axis / length : axis
            return [unit.x, unit.y, unit.z]
        }
    }

    private static let textureSuffixes = ["Resolution", "Rotation", "Translation", "MipMapInfo", "Texel"]

    /// `g_Texture{N}{Suffix}` → (N, Suffix).
    private static func textureUniform(_ name: String) -> (Int, String)? {
        guard name.hasPrefix("g_Texture") else { return nil }
        let rest = name.dropFirst("g_Texture".count)
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let slot = Int(digits) else { return nil }
        let suffix = String(rest.dropFirst(digits.count))
        return textureSuffixes.contains(suffix) ? (slot, suffix) : nil
    }

    /// Unbound slots read as zeros, except the sprite frame, which defaults to the whole texture.
    private static func textureValue(_ suffix: String, info: BuiltinTextureInfo?) -> [Float] {
        switch suffix {
        case "Resolution":
            guard let info else { return [0, 0, 0, 0] }
            return [info.allocatedSize.x, info.allocatedSize.y, info.contentSize.x, info.contentSize.y]
        case "Rotation":
            // WE's spritesheet vertex code: uv = translation + u·rotation.xy + v·rotation.zw,
            // so (1, 0, 0, 1) with translation 0 samples the texture unchanged.
            return flat(info?.spriteRotation ?? SIMD4(1, 0, 0, 1))
        case "Translation": return flat(info?.spriteTranslation ?? .zero)
        case "MipMapInfo": return [Float(info?.mipCount ?? 1)]
        case "Texel":
            guard let info, info.allocatedSize.x > 0, info.allocatedSize.y > 0 else { return [0, 0] }
            return flat(1 / info.allocatedSize)
        default: return [0]
        }
    }

    /// `g_AudioSpectrum{16,32,64}{Left,Right}` → (bands, isRight).
    private static func audioUniform(_ name: String) -> (Int, Bool)? {
        let prefix = "g_AudioSpectrum"
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        for bands in [16, 32, 64] {
            if rest == "\(bands)Left" { return (bands, false) }
            if rest == "\(bands)Right" { return (bands, true) }
        }
        return nil
    }

    private static func renderVarIndex(_ name: String) -> Int? {
        guard name.hasPrefix("g_RenderVar"), let index = Int(name.dropFirst("g_RenderVar".count)),
              (0...4).contains(index) else { return nil }
        return index
    }

    private static func flat(_ v: SIMD2<Float>) -> [Float] { [v.x, v.y] }
    private static func flat(_ v: SIMD3<Float>) -> [Float] { [v.x, v.y, v.z] }
    private static func flat(_ v: SIMD4<Float>) -> [Float] { [v.x, v.y, v.z, v.w] }
    private static func flat(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap(flat)
    }
}

/// The matrices each pass position uses (LWE; plan §2 "Matrices by pass position").
///
/// Clip space: spirv-cross is invoked without `--fixup-clipspace`, so translated WE vertex
/// shaders write `gl_Position` unchanged and Metal reads z in 0...1 instead of GL's −1...1.
/// Effect quads sit at z = 0, which both conventions keep visible, so no remap is needed for
/// 2D passes. The GL-convention ortho below maps near/far to −1...1; content outside z ∈ [0, 1]
/// after the multiply is clipped by Metal. 3D camera matrices (`SceneCamera`) are already Metal-style.
enum PassMatrices {
    /// OpenGL `glm::ortho(left, right, bottom, top, near, far)`.
    static func ortho(left: Float, right: Float, bottom: Float, top: Float,
                      near: Float = -1, far: Float = 1) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(2 / (right - left), 0, 0, 0),
            SIMD4(0, 2 / (top - bottom), 0, 0),
            SIMD4(0, 0, -2 / (far - near), 0),
            SIMD4(-(right + left) / (right - left), -(top + bottom) / (top - bottom),
                  -(far + near) / (far - near), 1)
        ))
    }

    /// Base draw of the layer image into its buffer: `ortho(0, w, 0, h)`.
    static func base(width: Float, height: Float) -> simd_float4x4 {
        ortho(left: 0, right: width, bottom: 0, top: height)
    }

    /// Intermediate passes draw a −1...1 quad.
    static let intermediate = matrix_identity_float4x4

    /// Final pass: the layer quad in scene space. `model` includes parent transforms and parallax.
    static func final(viewProjection: simd_float4x4, model: simd_float4x4) -> simd_float4x4 {
        viewProjection * model
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
