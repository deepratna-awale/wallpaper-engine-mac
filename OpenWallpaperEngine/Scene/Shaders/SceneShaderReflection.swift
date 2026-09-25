import Foundation

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
