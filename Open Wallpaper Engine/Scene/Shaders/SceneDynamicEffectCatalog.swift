import Foundation

struct SceneDynamicEffectDefinition: Decodable {
    let name: String?
    let passes: [SceneDynamicEffectPass]
    let textures: [String?]?

    var isMultiPass: Bool { passes.count > 1 }
}

struct SceneShaderUniformReflection: Codable {
    let name: String
    let type: String
    let semantic: String?

    var metalBinding: String {
        if type.hasPrefix("sampler"), let match = name.range(of: #"\d+$"#, options: .regularExpression) {
            return "fragmentTexture[\(name[match])]"
        }
        if name.caseInsensitiveCompare("g_Time") == .orderedSame { return "effect.time" }
        if name.localizedCaseInsensitiveContains("texcoord") { return "stage_in.textureCoordinate" }
        if name.localizedCaseInsensitiveContains("mask") { return "maskTexture" }
        return "uniform.\(name)"
    }
}

struct SceneShaderReflection: Codable {
    let uniforms: [SceneShaderUniformReflection]
    let textures: [String]
    let combos: [String: String]
}

extension SceneShaderReflection {
    /// Written next to the translated .metal so the original GLSL is only needed at conversion
    /// time, not on every catalog load.
    static func sidecarURL(for metalURL: URL) -> URL {
        metalURL.appendingPathExtension("reflection.json")
    }

    static func load(sidecarFor metalURL: URL) -> SceneShaderReflection? {
        guard let data = try? Data(contentsOf: sidecarURL(for: metalURL)) else { return nil }
        return try? JSONDecoder().decode(SceneShaderReflection.self, from: data)
    }

    func writeSidecar(for metalURL: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.sidecarURL(for: metalURL), options: .atomic)
    }
}

extension SceneShaderReflection {
    static func parse(source: Data) -> SceneShaderReflection {
        let text = String(data: source, encoding: .utf8) ?? ""
        var uniforms: [SceneShaderUniformReflection] = []
        var textures: [String] = []
        var combos: [String: String] = [:]
        let uniformPattern = #"uniform\s+(\w+)\s+(\w+)\s*;\s*(?://\s*([^\n]+))?"#
        if let expression = try? NSRegularExpression(pattern: uniformPattern) {
            let range = NSRange(text.startIndex..., in: text)
            for match in expression.matches(in: text, range: range) {
                guard let typeRange = Range(match.range(at: 1), in: text),
                      let nameRange = Range(match.range(at: 2), in: text) else { continue }
                let type = String(text[typeRange])
                let name = String(text[nameRange])
                let comment = match.range(at: 3).location == NSNotFound
                    ? nil : Range(match.range(at: 3), in: text).map { String(text[$0]) }
                uniforms.append(SceneShaderUniformReflection(name: name, type: type, semantic: comment))
                if type.hasPrefix("sampler") { textures.append(name) }
            }
        }
        let comboPattern = #"combo\"\s*:\s*\"([^\"]+)\"|combo\s+([A-Z_][A-Z0-9_]*)"#
        if let expression = try? NSRegularExpression(pattern: comboPattern) {
            let range = NSRange(text.startIndex..., in: text)
            for match in expression.matches(in: text, range: range) {
                let valueRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
                if let value = Range(valueRange, in: text) { combos[String(text[value])] = String(text[value]) }
            }
        }
        return SceneShaderReflection(uniforms: uniforms, textures: textures, combos: combos)
    }
}

struct SceneDynamicEffectPass: Decodable {
    let material: String?
    let shader: String?
    let vertexShader: String?
    let fragmentShader: String?
    let textures: [String?]?
    let constants: [String: SceneDynamicEffectConstant]?
    let uniforms: [String: SceneDynamicEffectConstant]?
    let blending: String?
    let sampler: String?
    let filter: String?
    let address: String?
    let renderTarget: String?

    enum CodingKeys: String, CodingKey {
        case material, shader, vertexShader, fragmentShader, textures, constants, uniforms
        case blending, sampler, filter, address, renderTarget, target, rendertarget
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        material = try container.decodeIfPresent(String.self, forKey: .material)
        shader = try container.decodeIfPresent(String.self, forKey: .shader)
        vertexShader = try container.decodeIfPresent(String.self, forKey: .vertexShader)
        fragmentShader = try container.decodeIfPresent(String.self, forKey: .fragmentShader)
        textures = try container.decodeIfPresent([String?].self, forKey: .textures)
        constants = try container.decodeIfPresent([String: SceneDynamicEffectConstant].self, forKey: .constants)
        uniforms = try container.decodeIfPresent([String: SceneDynamicEffectConstant].self, forKey: .uniforms)
        blending = try container.decodeIfPresent(String.self, forKey: .blending)
        sampler = try container.decodeIfPresent(String.self, forKey: .sampler)
        filter = try container.decodeIfPresent(String.self, forKey: .filter)
        address = try container.decodeIfPresent(String.self, forKey: .address)
        renderTarget = try container.decodeIfPresent(String.self, forKey: .renderTarget)
            ?? container.decodeIfPresent(String.self, forKey: .target)
            ?? container.decodeIfPresent(String.self, forKey: .rendertarget)
    }
}

struct SceneDynamicEffectCatalog {
    let definitions: [String: SceneDynamicEffectDefinition]
    private let shaderURLs: [String: URL]
    private let shaderReflections: [URL: SceneShaderReflection]
    private let assetsDirectory: URL?

    init(definitions: [String: SceneDynamicEffectDefinition], shaderURLs: [String: URL] = [:],
         shaderReflections: [URL: SceneShaderReflection] = [:], assetsDirectory: URL? = nil) {
        self.definitions = definitions
        self.shaderURLs = shaderURLs
        self.shaderReflections = shaderReflections
        self.assetsDirectory = assetsDirectory
    }

    func definition(for name: String) -> SceneDynamicEffectDefinition? {
        definitions[Self.canonicalName(name)]
    }

    /// A definition alone is not enough to draw with: both shader stages have to have survived
    /// translation for at least one pass.
    func isRenderable(_ name: String) -> Bool {
        guard let definition = definition(for: name) else { return false }
        return definition.passes.contains {
            shaderURL(for: $0, stage: "vert") != nil && shaderURL(for: $0, stage: "frag") != nil
        }
    }

    /// Workshop effects ship inside the wallpaper rather than the shared assets tree, so a
    /// wallpaper-local catalog is layered over the shared one and wins on key collisions.
    func merging(_ other: SceneDynamicEffectCatalog) -> SceneDynamicEffectCatalog {
        SceneDynamicEffectCatalog(
            definitions: definitions.merging(other.definitions) { _, local in local },
            shaderURLs: shaderURLs.merging(other.shaderURLs) { _, local in local },
            shaderReflections: shaderReflections.merging(other.shaderReflections) { _, local in local },
            assetsDirectory: assetsDirectory)
    }

    static func shared(for assetsDirectory: URL, wallpaperDirectory: URL?) -> SceneDynamicEffectCatalog {
        let base = shared(for: assetsDirectory)
        guard let wallpaperDirectory,
              wallpaperDirectory.standardizedFileURL != assetsDirectory.standardizedFileURL,
              FileManager.default.fileExists(
                atPath: wallpaperDirectory.appending(path: "effects", directoryHint: .isDirectory).path) else {
            return base
        }
        return base.merging(shared(for: wallpaperDirectory))
    }

    // Loading walks the whole assets tree (effect manifests, materials, shader sources and every
    // translated .metal). It only changes when the configured assets directory does, so memoize it.
    nonisolated(unsafe) private static var cachedCatalogs: [String: SceneDynamicEffectCatalog] = [:]
    private static let cacheLock = NSLock()

    static func shared(for assetsDirectory: URL) -> SceneDynamicEffectCatalog {
        let key = assetsDirectory.standardizedFileURL.path
        cacheLock.lock()
        let hit = cachedCatalogs[key]
        cacheLock.unlock()
        if let hit { return hit }

        // Deliberately not holding the lock across the load; a concurrent duplicate load is
        // cheaper than serialising every caller behind the first one.
        let catalog = load(from: assetsDirectory)
        let report = catalog.validationReport()
        OWELog.info(.shader, "Effect catalog: \(report.definitions) definitions, \(report.completePasses) complete passes, \(report.missingShaders) missing shader pairs")

        cacheLock.lock()
        cachedCatalogs[key] = catalog
        cacheLock.unlock()
        return catalog
    }

    static func invalidateSharedCache() {
        cacheLock.lock()
        cachedCatalogs.removeAll()
        cacheLock.unlock()
    }

    func shaderURL(for name: String, stage: String) -> URL? {
        shaderURLs["\(stage)|\(Self.shaderKey(name.lowercased()))"]
    }

    func shaderURL(for pass: SceneDynamicEffectPass, stage: String) -> URL? {
        let names = stage == "vert"
            ? [pass.vertexShader, pass.shader, pass.material]
            : [pass.fragmentShader, pass.shader, pass.material]
        return names.compactMap { $0 }.compactMap { shaderURL(for: $0, stage: stage) }.first
    }

    func reflection(for url: URL) -> SceneShaderReflection? {
        shaderReflections[url]
    }

    func macroConfiguration(for vertexURL: URL, fragmentURL: URL) -> String {
        let vertex = shaderReflections[vertexURL]?.combos ?? [:]
        let fragment = shaderReflections[fragmentURL]?.combos ?? [:]
        return vertex.merging(fragment, uniquingKeysWith: { _, fragmentValue in fragmentValue })
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
    }

    func textureURL(for path: String) -> URL? {
        guard let assetsDirectory else { return nil }
        let normalized = path.hasSuffix(".tex") || path.hasSuffix(".png") || path.hasSuffix(".jpg")
            ? path : "\(path).tex"
        let candidates = [
            assetsDirectory.appending(path: "materials/\(normalized)"),
            assetsDirectory.appending(path: normalized),
            assetsDirectory.appending(path: "materials/\(path).png"),
            assetsDirectory.appending(path: "materials/\(path).jpg")
        ]
        if let direct = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return direct
        }
        let basename = URL(fileURLWithPath: normalized).deletingPathExtension().lastPathComponent
        guard let enumerator = FileManager.default.enumerator(at: assetsDirectory, includingPropertiesForKeys: nil) else { return nil }
        return enumerator.compactMap { $0 as? URL }.first { candidate in
            let candidateBase = candidate.deletingPathExtension().lastPathComponent
            return candidateBase == basename && ["tex", "png", "jpg", "jpeg"].contains(candidate.pathExtension.lowercased())
        }
    }

    func validationReport() -> (definitions: Int, completePasses: Int, missingShaders: Int) {
        var completePasses = 0
        var missingShaders = 0
        for definition in definitions.values {
            for pass in definition.passes {
                let hasVertex = shaderURL(for: pass, stage: "vert") != nil
                let hasFragment = shaderURL(for: pass, stage: "frag") != nil
                if hasVertex && hasFragment { completePasses += 1 }
                if !hasVertex || !hasFragment { missingShaders += 1 }
            }
        }
        return (definitions.count, completePasses, missingShaders)
    }

    static func load(from assetsDirectory: URL) -> SceneDynamicEffectCatalog {
        let effectsDirectory = assetsDirectory.appending(path: "effects", directoryHint: .isDirectory)
        var definitions: [String: SceneDynamicEffectDefinition] = [:]
        guard let enumerator = FileManager.default.enumerator(at: effectsDirectory,
                                                               includingPropertiesForKeys: nil) else {
            return SceneDynamicEffectCatalog(definitions: definitions, assetsDirectory: assetsDirectory)
        }

        for case let url as URL in enumerator where url.lastPathComponent == "effect.json" {
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(SceneDynamicEffectManifest.self, from: data),
                  let key = manifest.replacementKey,
                  !key.isEmpty else { continue }

            var passes: [SceneDynamicEffectPass] = []
            for manifestPass in manifest.passes {
                guard let materialPath = manifestPass.material else { continue }
                let materialCandidates = [
                    url.deletingLastPathComponent().appending(path: materialPath),
                    assetsDirectory.appending(path: materialPath),
                    assetsDirectory.appending(path: "effects/\(key)/\(materialPath)")
                ]
                guard let materialURL = materialCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
                      let materialData = try? Data(contentsOf: materialURL),
                      let material = try? JSONDecoder().decode(SceneDynamicMaterial.self, from: materialData) else { continue }
                passes.append(contentsOf: material.passes)
            }
            guard !passes.isEmpty else { continue }
            let canonicalKey = canonicalName(key)
            definitions[canonicalKey] = SceneDynamicEffectDefinition(name: canonicalKey, passes: passes, textures: nil)
        }

        let cacheDirectory = assetsDirectory.appending(path: ".open-wallpaper-engine/shaders",
                                                        directoryHint: .isDirectory)
        SceneShaderTranslator.translateSharedShaders(in: assetsDirectory, cacheDirectory: cacheDirectory)
        SceneShaderTranslator.backfillMissingLibraries(in: cacheDirectory)
        var shaderURLs: [String: URL] = [:]
        if let shaderEnumerator = FileManager.default.enumerator(at: cacheDirectory,
                                                                   includingPropertiesForKeys: nil) {
            for case let url as URL in shaderEnumerator where url.pathExtension.lowercased() == "metal" {
                let stem = url.deletingPathExtension().lastPathComponent
                guard let identity = cachedShaderIdentity(fromStem: stem) else { continue }
                shaderURLs["\(identity.stage)|\(identity.key)"] = url
            }
        }
        var reflections: [URL: SceneShaderReflection] = [:]
        // Prefer the sidecar written at conversion time; it removes the need to re-read and
        // re-parse every GLSL source on each catalog load.
        for cached in shaderURLs.values where reflections[cached] == nil {
            if let sidecar = SceneShaderReflection.load(sidecarFor: cached) {
                reflections[cached] = sidecar
            }
        }
        let shaderRoots = [assetsDirectory.appending(path: "effects"), assetsDirectory.appending(path: "shaders")]
        for root in shaderRoots {
            guard let sourceEnumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in sourceEnumerator where ["frag", "vert"].contains(url.pathExtension.lowercased()) {
                let relative = url.path.replacingOccurrences(of: assetsDirectory.path + "/", with: "")
                guard let marker = relative.range(of: "/shaders/") else { continue }
                let logical = String(relative[marker.upperBound...]).dropLast(url.pathExtension.count + 1)
                let key = shaderKey(String(logical))
                guard let cached = shaderURLs["\(url.pathExtension.lowercased())|\(key)"],
                      reflections[cached] == nil,
                      let source = try? Data(contentsOf: url) else { continue }
                let reflection = SceneShaderReflection.parse(source: source)
                reflection.writeSidecar(for: cached)
                reflections[cached] = reflection
            }
        }
        return SceneDynamicEffectCatalog(definitions: definitions, shaderURLs: shaderURLs,
                                         shaderReflections: reflections, assetsDirectory: assetsDirectory)
    }

    private static func canonicalName(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    private static func shaderKey(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: ".frag", with: "")
            .replacingOccurrences(of: ".vert", with: "")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
    }

    /// Translated files are named "<flattened relative path>.<stage>.metal", e.g.
    /// "effects_blur_shaders_effects_blur_combine.frag.metal". Materials reference the logical
    /// name ("effects/blur_combine"), which is the segment after the final "_shaders_" with the
    /// path separators already flattened to underscores.
    private static func cachedShaderIdentity(fromStem stem: String) -> (key: String, stage: String)? {
        let lowered = stem.lowercased()
        let stage: String
        if lowered.hasSuffix(".frag") { stage = "frag" }
        else if lowered.hasSuffix(".vert") { stage = "vert" }
        else { return nil }
        let withoutStage = String(lowered.dropLast(stage.count + 1))
        let logical: String
        if let marker = withoutStage.range(of: "_shaders_", options: .backwards) {
            logical = String(withoutStage[marker.upperBound...])
        } else if withoutStage.hasPrefix("shaders_") {
            // Shaders living at a tree's own "shaders/" root (the global set, and the workshop
            // shaders a wallpaper ships) flatten to a stem that starts with the marker.
            logical = String(withoutStage.dropFirst("shaders_".count))
        } else {
            return nil
        }
        return logical.isEmpty ? nil : (logical, stage)
    }
}

private struct SceneDynamicEffectManifest: Decodable {
    let replacementKey: String?
    let passes: [SceneDynamicEffectManifestPass]

    enum CodingKeys: String, CodingKey { case replacementKey = "replacementkey", passes }
}

private struct SceneDynamicEffectManifestPass: Decodable {
    let material: String?
}

private struct SceneDynamicMaterial: Decodable {
    let passes: [SceneDynamicEffectPass]
}

struct SceneDynamicEffectConstant: Decodable {
    let value: String?
    let number: Double?
    let script: String?

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            value = try container.decodeIfPresent(String.self, forKey: .value)
            number = try container.decodeIfPresent(Double.self, forKey: .value)
            script = try container.decodeIfPresent(String.self, forKey: .script)
        } else {
            let container = try decoder.singleValueContainer()
            value = try? container.decode(String.self)
            number = try? container.decode(Double.self)
            script = nil
        }
    }

    private enum CodingKeys: String, CodingKey { case value, script }
}
