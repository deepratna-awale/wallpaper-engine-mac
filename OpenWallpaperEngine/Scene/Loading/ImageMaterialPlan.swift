import Foundation

/// An image layer's own material (`genericimage`, `genericimage2/3/4` or a Workshop shader),
/// resolved at load like pass 0 of an effect: the variant, its textures, combos and constants.
///
/// The renderer draws the layer with it: `g_Texture0` is the layer's image (after its effects),
/// and the layer's live transform, colour, alpha and brightness are its built-ins. A final class
/// so the renderer can key per-plan state on its identity.
final class ImageMaterialPlan {
    /// The material JSON, for logging.
    let materialPath: String
    /// `variant`, textures (slot 0 is `.current`, the layer image), constants and blending.
    let pass: SceneEffectPassPlan
    /// The shader reads its UVs through `g_Texture0Rotation/Translation` (`SPRITESHEET`), so the
    /// quad carries plain 0...1 texture coordinates.
    let usesSpriteSheetUniforms: Bool
    /// Material-authored factors of the uniforms the layer's live values drive (`g_Brightness`,
    /// `g_UserAlpha`); the live value is multiplied by them.
    let liveFactors: [String: Float]
    /// Texture slots sampled with clamp-to-edge (the `.tex` ClampUVs flag, or the object's
    /// `clampuvs` for the layer image); every other slot repeats, as in WE.
    let clampedSlots: Set<Int>

    init(materialPath: String, pass: SceneEffectPassPlan, usesSpriteSheetUniforms: Bool, liveFactors: [String: Float],
         clampedSlots: Set<Int> = [0]) {
        self.materialPath = materialPath
        self.pass = pass
        self.usesSpriteSheetUniforms = usesSpriteSheetUniforms
        self.liveFactors = liveFactors
        self.clampedSlots = clampedSlots
    }

    var readsSceneSnapshot: Bool { pass.readsSceneSnapshot }

    /// Uniforms that follow the layer's live colour, alpha and brightness rather than a constant.
    static let liveUniforms: Set<String> = ["g_Brightness", "g_UserAlpha", "g_Alpha", "g_Color", "g_Color4"]
}

enum ImageMaterialPlanError: Error, CustomStringConvertible {
    case missing(String)
    case invalid(String, Error)
    /// The material needs an engine feature that doesn't exist yet; the layer draws natively.
    case unsupported(String)

    var description: String {
        switch self {
        case .missing(let path): return "missing \(path)"
        case .invalid(let path, let error): return "\(path): \(error)"
        case .unsupported(let reason): return "unsupported: \(reason)"
        }
    }
}

/// Builds an `ImageMaterialPlan` from a model's material.
struct ImageMaterialPlanBuilder {
    let translator: ShaderVariantTranslator
    /// Reads a file relative to the wallpaper, falling back to the WE assets.
    let readFile: (String) -> Data?
    /// Loads a texture by WE name relative to a material path.
    let loadTexture: (_ name: String, _ materialPath: String) -> SceneMetalTextureSource?
    /// The combos WE's engine lays over every material of the scene (`SceneEngineCombos`).
    var sceneEngineCombos = SceneEngineCombos()

    /// nil when the material has no image to draw: no texture in slot 0 (solid layers' `flat`) or a
    /// render target there (composition layers), which keep their own paths.
    /// `colorBlendMode` is the object's WE blend mode (`BLENDMODE` combo), when authored; `clampUVs`
    /// is the object's `clampuvs`. `prelit` is set for a layer with effects or a puppet, whose
    /// lighting and reflection WE applies in a pass after them (docs/lighting-plan.md §2.3).
    func build(materialPath: String, colorBlendMode: Int?, clampUVs: Bool? = nil, prelit: Bool = false) throws -> ImageMaterialPlan? {
        try build(materialPath: materialPath, colorBlendMode: colorBlendMode, clampUVs: clampUVs, listsItsImage: true,
                  prelit: prelit)
    }

    /// A text object's font material (`materials/fonts/basefont*.json`, WE's `font` shader). It
    /// lists no texture: `g_Texture0` is the rasterised text, a coverage mask the shader tints with
    /// `g_Color4` (the text's colour, brightness and alpha). Clamped, since it is exactly the text.
    func buildText(materialPath: String) throws -> ImageMaterialPlan? {
        try build(materialPath: materialPath, colorBlendMode: nil, clampUVs: true, listsItsImage: false, prelit: false)
    }

    private func build(materialPath: String, colorBlendMode: Int?, clampUVs: Bool?,
                       listsItsImage: Bool, prelit: Bool) throws -> ImageMaterialPlan? {
        guard let data = readFile(materialPath) else { throw ImageMaterialPlanError.missing(materialPath) }
        let material: MaterialDocument
        do {
            material = try decodeTolerant(MaterialDocument.self, from: data)
        } catch {
            throw ImageMaterialPlanError.invalid(materialPath, error)
        }
        guard let materialPass = material.passes.first else { throw ImageMaterialPlanError.missing("\(materialPath) passes") }
        let image = materialPass.textures.first ?? nil
        if listsItsImage, image == nil || image!.hasPrefix("_rt_") {
            // Such a layer keeps its own draw, which has no scene blend: say so rather than drop it quietly.
            if let colorBlendMode, colorBlendMode != 0 {
                throw ImageMaterialPlanError.unsupported("colorBlendMode \(colorBlendMode) on \(materialPass.shader), which draws no image")
            }
            return nil
        }

        let loader = ShaderSourceLoader(readFile: readFile)
        let vertex = try loader.load(materialPass.shader, stage: .vertex)
        let fragment = try loader.load(materialPass.shader, stage: .fragment)

        var listed: [Int: SceneEffectTextureInput] = [:]
        var headers: [Int: Data] = [:]
        for (slot, name) in materialPass.textures.enumerated() where slot > 0 {
            guard let name else { continue }
            listed[slot] = try textureInput(named: name, materialPath: materialPath)
            if listed[slot] != nil, !name.hasPrefix("_rt_") { headers[slot] = textureHeader(name, materialPath: materialPath) }
        }
        let formats = Self.formatCombos(vertex.samplers + fragment.samplers, headers: headers)
        let combos = { (overrides: [[String: Int]]) in
            sceneEngineCombos.applied(to: ShaderVariantTranslator.resolveCombos(
                vertex: vertex, fragment: fragment, overrides: [materialPass.combos] + overrides + [formats],
                boundTextureSlots: Set(listed.keys).union([0]),
                textureFlags: headers.compactMapValues { TEXImageFormat.texiWord(1, in: $0) }))
        }

        let uniforms = (vertex.uniforms + fragment.uniforms).filter { !$0.isSampler }
            .reduce(into: [ShaderUniformDeclaration]()) { result, uniform in
                if !result.contains(where: { $0.name == uniform.name }) { result.append(uniform) }
            }
        let resolved = ShaderConstantResolver.resolve(
            uniforms: uniforms.map { .init(name: $0.name, glslType: $0.type, arrayCount: $0.arrayCount ?? 1, annotation: $0.annotation) },
            material: materialPass.constantSources(uniforms: uniforms), instance: [:])
        // The layer's live values drive these; a static material value scales them.
        var liveFactors: [String: Float] = [:]
        for name in ["g_Brightness", "g_UserAlpha"] {
            if let value = resolved.staticValues[name] { liveFactors[name] = value.float }
        }
        let constants = ShaderConstantResolver.ResolvedConstants(
            staticValues: resolved.staticValues.filter { !ImageMaterialPlan.liveUniforms.contains($0.key) },
            dynamic: resolved.dynamic)

        // One variant of the material: nil when it doesn't draw the layer image (slot 0).
        func pass(_ combos: [String: Int], blending: String) throws -> SceneEffectPassPlan? {
            let variant = try translator.variant(vertex: vertex, fragment: fragment, combos: combos)
            // A variant may declare samplers it never reads: `font` declares COLORFONT's colour
            // atlas (`g_Texture1`) in every variant, `genericimage4` its normal map and PBR mask
            // whenever `LIGHTING` or `REFLECTION` is on. SPIRV-Cross emits only the textures a stage
            // uses, and one it doesn't emit needs nothing bound.
            let msl = variant.vertexMSL + variant.fragmentMSL
            let sampled = Set(variant.textureSlots).filter { $0 == 0 || msl.contains("[[texture(\($0))]]") }
            guard sampled.contains(0) else { return nil }
            var inputs = listed.filter { sampled.contains($0.key) }
            for sampler in vertex.samplers + fragment.samplers {
                guard let slot = sampler.textureSlot, slot != 0, sampled.contains(slot), inputs[slot] == nil,
                      let name = sampler.defaultTexture else { continue }
                inputs[slot] = try textureInput(named: name, materialPath: materialPath)
            }
            inputs[0] = .current
            if let unbound = sampled.subtracting(inputs.keys).min() {
                throw ImageMaterialPlanError.unsupported("g_Texture\(unbound) has no texture")
            }
            return SceneEffectPassPlan(command: .render,
                                       variantKey: ShaderVariantTranslator.cacheKey(vertex: vertex, fragment: fragment, combos: combos),
                                       variant: variant, blending: blending, target: nil, textures: inputs, constants: constants)
        }

        let drawn = combos(colorBlendMode.map { [["BLENDMODE": $0]] } ?? [])
        if prelit, (drawn["LIGHTING"] ?? 0) != 0 || (drawn["REFLECTION"] ?? 0) != 0 {
            throw ImageMaterialPlanError.unsupported("LIGHTING or REFLECTION on a layer with effects or a puppet needs the prelighting pass (roadmap area 5)")
        }
        guard let layerPass = try pass(drawn, blending: materialPass.blending ?? "normal") else { return nil }

        var clampedSlots = Set<Int>()
        if clampUVs == true || image.map({ textureClamps($0, materialPath: materialPath) }) ?? true { clampedSlots.insert(0) }
        for (slot, input) in layerPass.textures {
            switch input {
            case .sceneSnapshot, .mipMappedFrameBuffer: clampedSlots.insert(slot)
            case .asset(let key, _):
                if textureClamps(String(key.dropFirst(materialPath.count + 1)), materialPath: materialPath) {
                    clampedSlots.insert(slot)
                }
            default: break
            }
        }
        return ImageMaterialPlan(materialPath: materialPath, pass: layerPass,
                                 usesSpriteSheetUniforms: (layerPass.variant?.combos["SPRITESHEET"] ?? 0) != 0,
                                 liveFactors: liveFactors, clampedSlots: clampedSlots)
    }

    /// The `.tex` ClampUVs flag (TEXI flags bit 2) of texture `name`, looked up like the texture
    /// loader does. A texture that isn't a `.tex` (or can't be read) clamps.
    func textureClamps(_ name: String, materialPath: String) -> Bool {
        guard let data = textureHeader(name, materialPath: materialPath), let flags = Self.texFlags(data) else { return true }
        return flags & Self.texClampUVsFlag != 0
    }

    /// The `.tex` file of texture `name`, looked up like the texture loader does; nil when there is none.
    func textureHeader(_ name: String, materialPath: String) -> Data? {
        let directory = (materialPath as NSString).deletingLastPathComponent
        let root = directory.split(separator: "/").first.map(String.init) ?? "materials"
        for path in ["\(directory)/\(name).tex", "\(root)/\(name).tex", "materials/\(name).tex", "\(name).tex"] {
            if let data = readFile(path) { return data }
        }
        return nil
    }

    /// `TEX<n>FORMAT` for the samplers annotated `"formatcombo": true` (0x1401a5c40: the bound
    /// texture's format), as `SceneEffectPlanBuilder` sets it: only the formats that load as the GPU
    /// samples them (RG88, R8, block-compressed); the others are expanded to RGBA on load.
    static func formatCombos(_ samplers: [ShaderUniformDeclaration], headers: [Int: Data]) -> [String: Int] {
        var combos: [String: Int] = [:]
        for sampler in samplers where (sampler.annotation["formatcombo"] as? NSNumber)?.boolValue == true {
            guard let slot = sampler.textureSlot, let header = headers[slot], let format = TEXImageFormat(texData: header),
                  format.isChannelReduced || format.isBlockCompressed else { continue }
            combos["TEX\(slot)FORMAT"] = Int(format.rawValue)
        }
        return combos
    }

    static let texClampUVsFlag: UInt32 = 2

    /// The flags word of a `.tex` header: `TEXV…\0TEXI…\0` then format, flags.
    static func texFlags(_ data: Data) -> UInt32? {
        let bytes = [UInt8](data.prefix(64))
        guard let texi = bytes.indices.first(where: { index in
            index + 4 <= bytes.count && bytes[index..<index + 4].elementsEqual("TEXI".utf8)
        }), let end = bytes[texi...].firstIndex(of: 0) else { return nil }
        let offset = end + 1 + 4
        guard offset + 4 <= bytes.count else { return nil }
        return bytes[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// nil (logged) for a texture that isn't there: the slot stays unbound, and so does its combo.
    private func textureInput(named name: String, materialPath: String) throws -> SceneEffectTextureInput? {
        if name == "_rt_FullFrameBuffer" { return .sceneSnapshot }
        if name == SceneMipMappedFrameBuffer.name { return .mipMappedFrameBuffer }
        if name.hasPrefix("_rt_") || name.hasPrefix("_alias_") {
            throw ImageMaterialPlanError.unsupported("render target \(name)")
        }
        guard let source = loadTexture(name, materialPath) else {
            OWELog.error(.scene, "Texture \(name) not found for \(materialPath)")
            return nil
        }
        return .asset(key: "\(materialPath)|\(name)", source: source)
    }
}
