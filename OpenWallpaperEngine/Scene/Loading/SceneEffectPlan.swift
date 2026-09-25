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
    /// Wallpaper directory first, then the WE assets: a wallpaper's own copy of a file wins.
    let roots: [URL]
    let translator: ShaderVariantTranslator
    /// Reads a file relative to the wallpaper (disk or package) or the WE assets.
    let readFile: (String) -> Data?
    /// Loads a texture by WE name (`util/noise`, `masks/foo`) relative to a material path.
    let loadTexture: (_ name: String, _ materialPath: String) -> SceneMetalTextureSource?

    private static let sceneSnapshotNames: Set<String> = ["_rt_FullFrameBuffer", "_rt_MipMappedFrameBuffer"]

    func build(_ effect: WEObjectEffect) throws -> SceneEffectPlan {
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
                                               instance: instance, fbos: document.fbos) {
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
                               instance: WEObjectEffectPass?, fbos: [EffectFBO],
                               shaderRoots: [URL]) throws -> SceneEffectPassPlan? {
        let loader = ShaderSourceLoader(roots: shaderRoots)
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
            if let input = textureInput(named: name, materialPath: materialPath, fboNames: fboNames) {
                inputs[slot] = input
            }
        }
        // Explicitly bound slots decide combos (MASK etc.); defaults below don't.
        let boundSlots = Set(inputs.keys)
        for sampler in samplers {
            guard let slot = sampler.textureSlot, inputs[slot] == nil, slot != 0,
                  let name = sampler.defaultTexture,
                  let input = textureInput(named: name, materialPath: materialPath, fboNames: fboNames) else { continue }
            inputs[slot] = input
        }
        if inputs[0] == nil { inputs[0] = .current }

        let combos = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment,
                                                           overrides: [materialPass.combos, instance?.combos ?? [:]],
                                                           boundTextureSlots: boundSlots.union([0]))
        guard Self.conditionsHold(pass.conditions, combos: combos) else { return nil }

        let variant = try translator.variant(vertex: vertex, fragment: fragment, combos: combos)
        let uniforms = (vertex.uniforms + fragment.uniforms).filter { !$0.isSampler }.reduce(into: [ShaderUniformDeclaration]()) { result, uniform in
            if !result.contains(where: { $0.name == uniform.name }) { result.append(uniform) }
        }
        let constants = ShaderConstantResolver.resolve(
            uniforms: uniforms.map { .init(name: $0.name, glslType: $0.type, arrayCount: $0.arrayCount ?? 1, annotation: $0.annotation) },
            material: materialPass.constantshadervalues.compactMapValues(\.valueSource),
            instance: (instance?.constants ?? [:]).compactMapValues(\.valueSource))
        return SceneEffectPassPlan(command: .render,
                                   variantKey: ShaderVariantTranslator.cacheKey(vertex: vertex, fragment: fragment, combos: combos),
                                   variant: variant, blending: materialPass.blending ?? "normal", target: pass.target,
                                   textures: inputs, constants: constants)
    }

    private func textureInput(named name: String, materialPath: String, fboNames: Set<String>) -> SceneEffectTextureInput? {
        if name == "previous" { return .previous }
        if fboNames.contains(name) { return .fbo(name) }
        if Self.sceneSnapshotNames.contains(name) { return .sceneSnapshot }
        if name.hasPrefix("_rt_") {
            OWELog.error(.scene, "Unsupported render target \(name) in \(materialPath)")
            return nil
        }
        guard let source = loadTexture(name, materialPath) else {
            OWELog.error(.scene, "Texture \(name) not found for \(materialPath)")
            return nil
        }
        return .asset(key: "\(materialPath)|\(name)", source: source)
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
                   instance: WEObjectEffectPass?, fbos: [EffectFBO]) throws -> SceneEffectPassPlan? {
        let roots = builder.roots.flatMap { root in
            directory.isEmpty ? [root] : [root.appending(path: directory, directoryHint: .isDirectory), root]
        }
        return try builder.buildPass(pass, materialPass: materialPass, materialPath: materialPath,
                                     instance: instance, fbos: fbos, shaderRoots: roots)
    }
}
