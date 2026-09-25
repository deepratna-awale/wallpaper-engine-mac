import Foundation

/// What feeds one texture slot of an effect pass.
enum SceneEffectTextureInput {
    /// The layer's image as it stands when the pass runs.
    case current
    /// The effect's input: the layer image before this effect's first pass.
    case previous
    /// A render target the effect declares in `fbos`.
    case fbo(String)
    /// The scene rendered so far (`_rt_FullFrameBuffer`, `_rt_MipMappedFrameBuffer`).
    case sceneSnapshot
    /// A texture asset; `key` identifies it for the renderer's texture cache.
    case asset(key: String, source: SceneMetalTextureSource)
}

enum SceneEffectPassCommand {
    case render
    case copy(source: String, target: String)
    case swap(String, String)
}

/// One pass of an effect, fully resolved at scene load: shader variant, bindings, constants.
struct SceneEffectPassPlan {
    let command: SceneEffectPassCommand
    let variantKey: String
    let variant: TranslatedShaderVariant?
    /// Material blending (`normal`, `translucent`, `additive`, `disabled`).
    let blending: String
    /// Render into this effect FBO; nil renders into the layer's ping-pong buffer.
    let target: String?
    let textures: [Int: SceneEffectTextureInput]
    let constants: ShaderConstantResolver.ResolvedConstants
    /// `.tex` flags of the asset textures, by slot: how WE samples each (`clampUVs`,
    /// `noInterpolation`). A slot without flags repeats with bilinear filtering.
    var textureFlags: [Int: TEXFlags] = [:]

    var readsSceneSnapshot: Bool {
        textures.values.contains { if case .sceneSnapshot = $0 { return true } else { return false } }
    }
}

/// One WE effect on one layer, ready for the effect graph executor.
struct SceneEffectPlan {
    /// The effect.json path, for logging.
    let file: String
    let fbos: [EffectFBO]
    let passes: [SceneEffectPassPlan]
}

enum SceneEffectPlanError: Error, CustomStringConvertible {
    case missing(String)
    case invalid(String, Error)

    var description: String {
        switch self {
        case .missing(let path): return "missing \(path)"
        case .invalid(let path, let error): return "\(path): \(error)"
        }
    }
}

/// Resolves a scene object's effect into a `SceneEffectPlan`: loads effect.json and its materials,
/// resolves combos, textures and constants per pass, and translates each shader variant.
struct SceneEffectPlanBuilder {
    let translator: ShaderVariantTranslator
    /// Reads a file relative to the wallpaper (disk or package), falling back to the WE assets:
    /// a wallpaper's own copy of a file wins. Shaders are read through it too.
    let readFile: (String) -> Data?
    /// Loads a texture by WE name (`util/noise`, `masks/foo`) relative to a material path.
    let loadTexture: (_ name: String, _ materialPath: String) -> SceneMetalTextureSource?

    private static let sceneSnapshotNames: Set<String> = ["_rt_FullFrameBuffer", "_rt_MipMappedFrameBuffer"]

    /// `overrides` returns the user's edit for a WE material key (inspector), as a WE value string.
    func build(_ effect: WEObjectEffect, overrides: (String) -> SceneEffectOverride? = { _ in nil }) throws -> SceneEffectPlan {
        // An effect's materials, shaders and textures live under its own folder
        // (`effects/tint/materials/...`), like a small asset root of its own.
        let effectDirectory = (effect.file as NSString).deletingLastPathComponent
        let scoped = Scoped(builder: self, directory: effectDirectory)
        let document: EffectDocument = try decode(effect.file)
        let instancePasses = effect.passes ?? []
        var passes: [SceneEffectPassPlan] = []
        for (index, pass) in document.passes.enumerated() {
            let instance = index < instancePasses.count ? instancePasses[index] : nil
            if let command = pass.commandKind {
                switch command {
                case .copy:
                    guard let source = pass.source, let target = pass.target else { continue }
                    passes.append(Self.commandPass(.copy(source: source, target: target)))
                case .swap:
                    guard let source = pass.source, let target = pass.target else { continue }
                    passes.append(Self.commandPass(.swap(source, target)))
                }
                continue
            }
            guard let materialPath = pass.material else { continue }
            let (material, resolvedMaterialPath): (MaterialDocument, String) = try scoped.decode(materialPath)
            guard let materialPass = material.passes.first else { throw SceneEffectPlanError.missing("\(materialPath) passes") }
            if let plan = try scoped.buildPass(pass, materialPass: materialPass, materialPath: resolvedMaterialPath,
                                               instance: instance, fbos: document.fbos, overrides: overrides) {
                passes.append(plan)
            }
        }
        return SceneEffectPlan(file: effect.file, fbos: document.fbos, passes: passes)
    }

    private static func commandPass(_ command: SceneEffectPassCommand) -> SceneEffectPassPlan {
        SceneEffectPassPlan(command: command, variantKey: "", variant: nil, blending: "normal", target: nil,
                            textures: [:], constants: ShaderConstantResolver.resolve(uniforms: [], material: [:], instance: [:]))
    }

    fileprivate func buildPass(_ pass: EffectPass, materialPass: MaterialPass, materialPath: String,
                               instance: WEObjectEffectPass?, fbos: [EffectFBO], overrides: (String) -> SceneEffectOverride?,
                               shaderReader: @escaping (String) -> Data?, effectDirectory: String = "") throws -> SceneEffectPassPlan? {
        let loader = ShaderSourceLoader(readFile: shaderReader)
        let vertex = try loader.load(materialPass.shader, stage: .vertex)
        let fragment = try loader.load(materialPass.shader, stage: .fragment)

        // Texture names per slot: material, then instance overrides (nil keeps), then binds.
        var names: [Int: String] = [:]
        for (slot, name) in materialPass.textures.enumerated() { if let name { names[slot] = name } }
        for (slot, name) in (instance?.textures ?? []).enumerated() { if let name { names[slot] = name } }
        let fboNames = Set(fbos.map(\.name))
        for bind in pass.bind { names[bind.index] = bind.name }

        let samplers = vertex.samplers + fragment.samplers
        var inputs: [Int: SceneEffectTextureInput] = [:]
        for (slot, name) in names {
            if let input = textureInput(named: name, materialPath: materialPath, fboNames: fboNames,
                                        effectDirectory: effectDirectory) {
                inputs[slot] = input
            }
        }
        // Explicitly bound slots decide combos (MASK etc.); defaults below don't.
        let boundSlots = Set(inputs.keys)
        let combos = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment,
                                                           overrides: [materialPass.combos, instance?.combos ?? [:]],
                                                           boundTextureSlots: boundSlots.union([0]))
        guard Self.conditionsHold(pass.conditions, combos: combos) else { return nil }

        let variant = try translator.variant(vertex: vertex, fragment: fragment, combos: combos)
        // Only slots the compiled variant samples need a texture: a sampler behind a disabled
        // combo (e.g. a lighting atlas) is declared but never read.
        let sampled = Set(variant.textureSlots)
        inputs = inputs.filter { sampled.contains($0.key) }
        for sampler in samplers {
            guard let slot = sampler.textureSlot, sampled.contains(slot), inputs[slot] == nil, slot != 0,
                  let name = sampler.defaultTexture,
                  let input = textureInput(named: name, materialPath: materialPath, fboNames: fboNames,
                                           effectDirectory: effectDirectory) else { continue }
            inputs[slot] = input
        }
        if inputs[0] == nil { inputs[0] = .current }
        let uniforms = (vertex.uniforms + fragment.uniforms).filter { !$0.isSampler }.reduce(into: [ShaderUniformDeclaration]()) { result, uniform in
            if !result.contains(where: { $0.name == uniform.name }) { result.append(uniform) }
        }
        let constants = ShaderConstantResolver.resolve(
            uniforms: uniforms.map { .init(name: $0.name, glslType: $0.type, arrayCount: $0.arrayCount ?? 1, annotation: $0.annotation) },
            material: materialPass.constantshadervalues.compactMapValues(\.valueSource),
            instance: Self.applyingOverrides(overrides, to: (instance?.constants ?? [:]).compactMapValues(\.valueSource),
                                             uniforms: uniforms))
        var textureFlags: [Int: TEXFlags] = [:]
        for (slot, input) in inputs {
            guard case .asset(let key, _) = input else { continue }
            let name = String(key.dropFirst(materialPath.count + 1))
            if let flags = self.textureFlags(named: name, materialPath: materialPath, effectDirectory: effectDirectory) {
                textureFlags[slot] = flags
            }
        }
        return SceneEffectPassPlan(command: .render,
                                   variantKey: ShaderVariantTranslator.cacheKey(vertex: vertex, fragment: fragment, combos: combos),
                                   variant: variant, blending: materialPass.blending ?? "normal", target: pass.target,
                                   textures: inputs, constants: constants, textureFlags: textureFlags)
    }

    /// The `.tex` flags of texture `name`, found where `loadTexture` finds it (then in the effect's
    /// own `materials/`); nil for a texture that isn't a `.tex`.
    private func textureFlags(named name: String, materialPath: String, effectDirectory: String) -> TEXFlags? {
        var header = ParticleMaterialPlanBuilder.textureHeader(named: name, materialPath: materialPath, readFile: readFile)
        if header == nil, !effectDirectory.isEmpty {
            header = ParticleMaterialPlanBuilder.textureHeader(named: "\(effectDirectory)/materials/\(name)",
                                                               materialPath: materialPath, readFile: readFile)
        }
        return header.flatMap(TEXFlags.init(texData:))
    }

    private func textureInput(named name: String, materialPath: String, fboNames: Set<String>,
                              effectDirectory: String) -> SceneEffectTextureInput? {
        if name == "previous" { return .previous }
        if fboNames.contains(name) { return .fbo(name) }
        if Self.sceneSnapshotNames.contains(name) { return .sceneSnapshot }
        if name.hasPrefix("_rt_") {
            OWELog.error(.scene, "Unsupported render target \(name) in \(materialPath)")
            return nil
        }
        // Effects ship some textures in their own `materials/` folder.
        guard let source = loadTexture(name, materialPath)
                ?? (effectDirectory.isEmpty ? nil : loadTexture("\(effectDirectory)/materials/\(name)", materialPath)) else {
            OWELog.error(.scene, "Texture \(name) not found for \(materialPath)")
            return nil
        }
        return .asset(key: "\(materialPath)|\(name)", source: source)
    }

    /// The user's inspector edits win over the scene's authored value. A plain edit is a static
    /// literal, so an edited chain can still be reused frame to frame (an edit rebuilds the scene
    /// content). A music-synced edit is bound to its user property instead, so it's resolved every
    /// frame and modulated by the audio level like any other synced numeric value.
    static func applyingOverrides(_ overrides: (String) -> SceneEffectOverride?, to instance: [String: SceneValueSource],
                                  uniforms: [ShaderUniformDeclaration]) -> [String: SceneValueSource] {
        var result = instance
        for uniform in uniforms {
            guard let key = uniform.materialKey, let override = overrides(key),
                  let value = ShaderValue(string: override.value) else { continue }
            result = result.filter { $0.key.caseInsensitiveCompare(key) != .orderedSame }
            result[key] = override.isMusicSynced
                ? .user(name: override.property, condition: nil, fallback: .literal(value))
                : .literal(value)
        }
        return result
    }

    /// WE conditions are a list of combo requirements; any one fully matching enables the pass.
    static func conditionsHold(_ conditions: EffectConditions?, combos: [String: Int]) -> Bool {
        guard let conditions, !conditions.isEmpty else { return true }
        return conditions.contains { requirement in
            requirement.allSatisfy { combos[$0.key.uppercased()] == $0.value }
        }
    }

    fileprivate func decode<T: Decodable>(_ path: String) throws -> T {
        guard let data = readFile(path) else { throw SceneEffectPlanError.missing(path) }
        do {
            return try decodeTolerant(T.self, from: data)
        } catch {
            throw SceneEffectPlanError.invalid(path, error)
        }
    }
}

/// Lookups for one effect: its own folder first, then the wallpaper/asset roots.
private struct Scoped {
    let builder: SceneEffectPlanBuilder
    let directory: String

    func candidates(_ path: String) -> [String] {
        directory.isEmpty ? [path] : ["\(directory)/\(path)", path]
    }

    func decode<T: Decodable>(_ path: String) throws -> (T, String) {
        for candidate in candidates(path) where builder.readFile(candidate) != nil {
            return (try builder.decode(candidate), candidate)
        }
        throw SceneEffectPlanError.missing(path)
    }

    func buildPass(_ pass: EffectPass, materialPass: MaterialPass, materialPath: String,
                   instance: WEObjectEffectPass?, fbos: [EffectFBO],
                   overrides: (String) -> SceneEffectOverride?) throws -> SceneEffectPassPlan? {
        let read = builder.readFile
        let scopes = candidates
        return try builder.buildPass(pass, materialPass: materialPass, materialPath: materialPath,
                                     instance: instance, fbos: fbos, overrides: overrides,
                                     shaderReader: { path in scopes(path).lazy.compactMap(read).first },
                                     effectDirectory: directory)
    }
}
