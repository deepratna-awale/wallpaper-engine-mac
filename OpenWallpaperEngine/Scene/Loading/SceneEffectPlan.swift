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
    /// The pass's index in effect.json's `passes`, which scene.json's `passes` and scripts
    /// (`IEffect.getMaterial(i)`) address it by.
    var materialIndex = 0

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
    /// The effect's index in its object's `effects` (what scripts' `getEffect(i)` addresses).
    var effectIndex = 0
    /// scene.json `visible` (authored or user-bound). A hidden effect is built but skipped, so a
    /// script can show it (`thisObject.visible = true`).
    var visible = true
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
    /// The combos WE's engine lays over every material of the scene (`SceneEngineCombos`).
    var sceneEngineCombos = SceneEngineCombos()

    private static let sceneSnapshotNames: Set<String> = ["_rt_FullFrameBuffer", "_rt_MipMappedFrameBuffer"]

    /// `overrides` returns the user's edit for a WE material key (inspector), as a WE value string.
    /// `owner` is the layer's id and the effect's index in its `effects`: an animated constant of
    /// scene.json pass `p` is the timeline of `SceneAnimationSite(.material(object, effect, p), key)`.
    func build(_ effect: WEObjectEffect, owner: (object: Int, effect: Int)? = nil,
               overrides: (String) -> SceneEffectOverride? = { _ in nil }) throws -> SceneEffectPlan {
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
            let site = owner.map { owner in
                { (key: String) in
                    SceneAnimationSite(owner: .material(object: owner.object, effect: owner.effect, pass: index), key: key)
                }
            }
            if var plan = try scoped.buildPass(pass, materialPass: materialPass, materialPath: resolvedMaterialPath,
                                               instance: instance, fbos: document.fbos, overrides: overrides,
                                               animationSite: site) {
                plan.materialIndex = index
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
                               animationSite: ((String) -> SceneAnimationSite)? = nil,
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
        let formats = formatCombos(samplers, names: names, materialPath: materialPath, effectDirectory: effectDirectory)
        let combos = sceneEngineCombos.applied(to: ShaderVariantTranslator.resolveCombos(
            vertex: vertex, fragment: fragment,
            overrides: [formats, materialPass.combos, instance?.combos ?? [:],
                        Self.comboOverrides(overrides, declared: vertex.combos + fragment.combos)],
            boundTextureSlots: boundSlots.union([0])))
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
            instance: Self.applyingOverrides(overrides, to: Self.instanceSources(instance, animationSite: animationSite),
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

    /// The `.tex` flags of texture `name`; nil for a texture that isn't a `.tex`.
    private func textureFlags(named name: String, materialPath: String, effectDirectory: String) -> TEXFlags? {
        textureHeader(named: name, materialPath: materialPath, effectDirectory: effectDirectory).flatMap(TEXFlags.init(texData:))
    }

    /// The `.tex` header of texture `name`, found where `loadTexture` finds it (then in the
    /// effect's own `materials/`); nil for a texture that isn't a `.tex`.
    private func textureHeader(named name: String, materialPath: String, effectDirectory: String) -> Data? {
        if let header = ParticleMaterialPlanBuilder.textureHeader(named: name, materialPath: materialPath, readFile: readFile) {
            return header
        }
        guard !effectDirectory.isEmpty else { return nil }
        return ParticleMaterialPlanBuilder.textureHeader(named: "\(effectDirectory)/materials/\(name)",
                                                         materialPath: materialPath, readFile: readFile)
    }

    /// `TEX<n>FORMAT` for the samplers annotated `"formatcombo": true`, from the format of the
    /// texture bound there (or the sampler's default), as WE sets it: lightshafts reads an R8 or
    /// RG88 gradient map as `.rrr`, refraction decodes a normal map by its format. Only formats
    /// that load as the GPU samples them need it; the others are expanded to RGBA on load.
    private func formatCombos(_ samplers: [ShaderUniformDeclaration], names: [Int: String], materialPath: String,
                              effectDirectory: String) -> [String: Int] {
        var combos: [String: Int] = [:]
        for sampler in samplers where (sampler.annotation["formatcombo"] as? NSNumber)?.boolValue == true {
            guard let slot = sampler.textureSlot, let name = names[slot] ?? sampler.defaultTexture,
                  let header = textureHeader(named: name, materialPath: materialPath, effectDirectory: effectDirectory),
                  let format = TEXImageFormat(texData: header),
                  format.isChannelReduced || format.isBlockCompressed else { continue }
            combos["TEX\(slot)FORMAT"] = Int(format.rawValue)
        }
        return combos
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

    /// scene.json's constants of one pass, each animated one bound to its timeline's site. A
    /// material file's own constants have no site: WE animates only the scene's (§1.1).
    private static func instanceSources(_ instance: WEObjectEffectPass?,
                                        animationSite: ((String) -> SceneAnimationSite)?) -> [String: SceneValueSource] {
        var sources: [String: SceneValueSource] = [:]
        for (key, raw) in instance?.constants ?? [:] {
            guard let source = raw.valueSource else { continue }
            sources[key] = animationSite.map { source.bindingAnimation(to: $0(key)) } ?? source
        }
        return sources
    }

    /// The user's inspector edits win over the scene's authored value, not over its timeline or
    /// script. A plain edit is a static literal, so an edited chain can still be reused frame to
    /// frame (an edit rebuilds the scene content). A music-synced edit is bound to its user property instead, so it's resolved every
    /// frame and modulated by the audio level like any other synced numeric value.
    static func applyingOverrides(_ overrides: (String) -> SceneEffectOverride?, to instance: [String: SceneValueSource],
                                  uniforms: [ShaderUniformDeclaration]) -> [String: SceneValueSource] {
        var result = instance
        for uniform in uniforms {
            guard let key = uniform.materialKey, let override = overrides(key),
                  let value = ShaderValue(string: override.value) else { continue }
            let authored = result.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
            result = result.filter { $0.key.caseInsensitiveCompare(key) != .orderedSame }
            let edited: SceneValueSource = override.isMusicSynced
                ? .user(name: override.property, condition: nil, fallback: .literal(value))
                : .literal(value)
            // An edit is a user value: an authored timeline (and script) still wins over it (§2.6).
            result[key] = authored?.replacingBase(with: edited) ?? edited
        }
        return result
    }

    /// The user's inspector choice for a combo the shaders declare wins over the material and the
    /// scene (stored under `SceneEffectParameters.comboOverrideKey`).
    static func comboOverrides(_ overrides: (String) -> SceneEffectOverride?,
                               declared: [ShaderComboDeclaration]) -> [String: Int] {
        var result: [String: Int] = [:]
        for combo in declared where result[combo.name] == nil {
            guard let stored = overrides(SceneEffectParameters.comboOverrideKey(combo.name)),
                  let value = Int(stored.value) else { continue }
            result[combo.name] = value
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
                   instance: WEObjectEffectPass?, fbos: [EffectFBO], overrides: (String) -> SceneEffectOverride?,
                   animationSite: ((String) -> SceneAnimationSite)?) throws -> SceneEffectPassPlan? {
        let read = builder.readFile
        let scopes = candidates
        return try builder.buildPass(pass, materialPass: materialPass, materialPath: materialPath,
                                     instance: instance, fbos: fbos, overrides: overrides, animationSite: animationSite,
                                     shaderReader: { path in scopes(path).lazy.compactMap(read).first },
                                     effectDirectory: directory)
    }
}
