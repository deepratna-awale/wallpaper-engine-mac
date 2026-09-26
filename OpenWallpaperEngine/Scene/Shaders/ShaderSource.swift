import Foundation

enum ShaderStage: String, CaseIterable {
    case vertex = "vert"
    case fragment = "frag"
}

/// `// [COMBO] {"combo":"MASK","default":0,...}`: a preprocessor switch the shader declares.
struct ShaderComboDeclaration: Equatable {
    let name: String
    let defaultValue: Int
}

/// A `uniform` declaration and its trailing `// {...}` annotation.
struct ShaderUniformDeclaration {
    let type: String
    let name: String
    let arrayCount: Int?
    let annotation: [String: Any]

    /// The key `constantshadervalues` use for this uniform.
    var materialKey: String? { annotation["material"] as? String }
    /// Set when the sampler switches a combo on while a texture is bound (e.g. `MASK`).
    var combo: String? { annotation["combo"] as? String }
    /// The combos of a PBR mask's channels (`"components"`, r first: `METALLIC_MAP`,
    /// `ROUGHNESS_MAP`, `REFLECTION_MAP`, `EMISSIVE_MAP` on the image and model shaders). WE
    /// switches component k on when the bound texture's `.tex` flags have bit 20 + k, which the
    /// editor sets for each channel painted (0x14016c800).
    var componentCombos: [String] {
        (annotation["components"] as? [Any] ?? []).map { ($0 as? [String: Any])?["combo"] as? String ?? "" }
    }
    /// `util/noise` etc.: what fills the slot when nothing else does.
    var defaultTexture: String? { annotation["default"] as? String }
    var isSampler: Bool { type.hasPrefix("sampler") }

    /// `g_TextureN` → N.
    var textureSlot: Int? {
        guard isSampler, name.hasPrefix("g_Texture") else { return nil }
        return Int(name.dropFirst("g_Texture".count))
    }
}

/// One WE shader stage with its includes inlined and its declarations parsed.
struct ShaderSource {
    let stage: ShaderStage
    /// Relative path as WE names it, e.g. `shaders/effects/shake.frag`.
    let path: String
    let text: String
    let combos: [ShaderComboDeclaration]
    let uniforms: [ShaderUniformDeclaration]

    var samplers: [ShaderUniformDeclaration] { uniforms.filter(\.isSampler) }

    /// Shared by copies of this source, so every variant of it reuses one analysis.
    private let preludeAnalysisCache = PreludeAnalysisCache()

    /// `ShaderPrelude.SourceAnalysis` of `text`, computed on first use.
    var preludeAnalysis: ShaderPrelude.SourceAnalysis { preludeAnalysisCache.value(for: text) }

    /// `text` for one variant: each `#require LightingV1` replaced by the source WE generates for
    /// `combos` (`LightingV1Require`).
    func text(combos: [String: Int]) -> String {
        ShaderSourceLoader.expandRequires(in: text, combos: combos)
    }
}

/// Holds one source's prelude analysis. Thread-safe: `lock` owns `analysis`.
private final class PreludeAnalysisCache {
    private let lock = NSLock()
    private var analysis: ShaderPrelude.SourceAnalysis?

    func value(for text: String) -> ShaderPrelude.SourceAnalysis {
        lock.withLock {
            if let analysis { return analysis }
            let computed = ShaderPrelude.SourceAnalysis(source: text)
            analysis = computed
            return computed
        }
    }
}

enum ShaderSourceError: Error, CustomStringConvertible {
    case notFound(String)
    case unreadable(String)
    case missingInclude(String, in: String)

    var description: String {
        switch self {
        case .notFound(let path): return "shader not found: \(path)"
        case .unreadable(let path): return "shader is not UTF-8: \(path)"
        case .missingInclude(let name, let path): return "include \(name) not found for \(path)"
        }
    }
}

/// Finds and prepares shader sources. Roots are searched in order, so a wallpaper's own copy of a
/// shader wins over the Wallpaper Engine install (library copies of built-ins can be older).
struct ShaderSourceLoader {
    /// Reads a path relative to an asset root; the first root that has it wins.
    let readFile: (String) -> Data?

    init(readFile: @escaping (String) -> Data?) {
        self.readFile = readFile
    }

    init(roots: [URL]) {
        self.init(readFile: { path in
            for root in roots {
                if let data = FileManager.default.contents(atPath: root.appending(path: path).path) { return data }
            }
            return nil
        })
    }

    func load(_ path: String, stage: ShaderStage) throws -> ShaderSource {
        let file = path.hasSuffix(".\(stage.rawValue)") ? path : "\(path).\(stage.rawValue)"
        let text = try read(candidates: [file, "shaders/\(file)"], label: file)
        let expanded = try Self.inlineIncludes(in: text, path: file) { name in
            try read(candidates: ["shaders/\(name)", name], label: name)
        }
        return ShaderSource(stage: stage, path: file, text: expanded,
                            combos: Self.parseCombos(expanded), uniforms: Self.parseUniforms(expanded))
    }

    private func read(candidates: [String], label: String) throws -> String {
        for candidate in candidates {
            guard let data = readFile(candidate) else { continue }
            guard let text = String(data: data, encoding: .utf8) else { throw ShaderSourceError.unreadable(candidate) }
            return text
        }
        throw ShaderSourceError.notFound(label)
    }

    // MARK: - Includes

    private static let includePattern = try! NSRegularExpression(pattern: #"(?m)^[ \t]*#include[ \t]+"([^"]+)"[^\n]*$"#)
    private static let requirePattern = try! NSRegularExpression(pattern: #"(?m)^[ \t]*#require[ \t]+(\w+)[^\n]*$"#)

    /// Includes are inlined once each, after the last top-level `attribute`/`varying`/`uniform`/
    /// `struct` before `main` and outside any `#if` (linux-wallpaperengine's rule): WE headers use
    /// the stage's declarations, and shaders with two `main`s wrapped in `#if` get them up front.
    static func inlineIncludes(in text: String, path: String,
                               resolve: (String) throws -> String) throws -> String {
        var seen = Set<String>()
        // Dependencies first: a header's own includes are emitted before the header itself, and
        // sibling includes keep their order.
        var bodies: [String] = []
        func collect(_ source: String) throws -> String {
            var result = source
            let matches = includePattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
            for match in matches {
                let name = String(source[Range(match.range(at: 1), in: source)!])
                guard seen.insert(name).inserted else { continue }
                let body: String
                do { body = try resolve(name) } catch { throw ShaderSourceError.missingInclude(name, in: path) }
                bodies.append(try collect(body))
            }
            for match in matches.reversed() {
                let name = String(source[Range(match.range(at: 1), in: source)!])
                result.replaceSubrange(Range(match.range, in: result)!, with: "// (included) #include \"\(name)\"")
            }
            return result
        }
        var main = try collect(text)
        main = dropUnmatchedEndifs(in: commentUnknownRequires(in: main, path: path))
        guard !bodies.isEmpty else { return main }
        let blob = "\n" + bodies.joined(separator: "\n") + "\n"
        let insertion = includeInsertionOffset(in: main)
        let index = main.utf16.index(main.utf16.startIndex, offsetBy: insertion)
        main.insert(contentsOf: blob, at: index)
        return main
    }

    private static let ifPattern = NSRegularExpression.shader(#"^#\s*if"#)
    private static let endifPattern = NSRegularExpression.shader(#"^#\s*endif\b"#)
    private static let mainPattern = NSRegularExpression.shader(#"\bvoid\s+main\s*\("#)
    private static let declarationPattern = NSRegularExpression.shader(#"^(attribute|varying|uniform|struct)\s"#)

    /// WE's compiler ignores an `#endif` that closes nothing; glslang rejects the whole shader.
    static func dropUnmatchedEndifs(in text: String) -> String {
        var depth = 0
        var lines = text.components(separatedBy: "\n")
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if ifPattern.matches(trimmed) { depth += 1 }
            if endifPattern.matches(trimmed) {
                if depth == 0 { lines[index] = "// (unmatched) " + lines[index] } else { depth -= 1 }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Character offset (UTF-16) where includes go.
    static func includeInsertionOffset(in text: String) -> Int {
        let lines = text.components(separatedBy: "\n")
        let mains = lines.filter { mainPattern.matches($0) }.count
        guard mains < 2 else { return 0 }
        var depth = 0
        var offset = 0
        var insertion = 0
        // Braces open at the start of the line, so a multi-line `struct` is passed whole.
        var braces = 0
        var pending = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if") { depth += 1 }
            if trimmed.hasPrefix("#endif") { depth = max(0, depth - 1) }
            let lineEnd = offset + line.utf16.count + 1
            if mainPattern.matches(trimmed) { break }
            if depth == 0, braces == 0,
               declarationPattern.matches(trimmed) {
                pending = true
            }
            braces += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            if pending, braces <= 0 {
                insertion = lineEnd
                pending = false
            }
            offset = lineEnd
        }
        return min(insertion, text.utf16.count)
    }

    /// WE knows one `#require`, `LightingV1`, whose source depends on the variant's combos: it
    /// stays in the text until `expandRequires(in:combos:)`. Any other name is an error in WE's
    /// preprocessor too (0x14016c0ec); it becomes a comment and is logged.
    static func commentUnknownRequires(in text: String, path: String) -> String {
        var result = text
        for match in requirePattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let name = String(text[Range(match.range(at: 1), in: text)!])
            guard name != LightingV1Require.name else { continue }
            OWELog.error(.shader, "\(path): unknown #require \(name); WE generates only \(LightingV1Require.name)")
            result.replaceSubrange(Range(match.range, in: result)!, with: "// (unsupported) #require \(name)")
        }
        return result
    }

    /// `text` with each `#require LightingV1` replaced by WE's generated source for `combos`, which
    /// is empty unless `LIGHTING` is on (docs/lighting-plan.md §2.1).
    static func expandRequires(in text: String, combos: [String: Int]) -> String {
        let matches = requirePattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        let source = LightingV1Require.source(combos: combos)
        var result = text
        for match in matches.reversed() where text[Range(match.range(at: 1), in: text)!] == LightingV1Require.name {
            result.replaceSubrange(Range(match.range, in: result)!, with: source)
        }
        return result
    }

    // MARK: - Declarations

    private static let comboPattern = try! NSRegularExpression(pattern: #"//\s*\[COMBO\]\s*(\{[^\n]*\})"#)
    private static let uniformPattern = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*uniform[ \t]+(?:(?:lowp|mediump|highp)[ \t]+)?(\w+)[ \t]+(\w+)[ \t]*(?:\[[ \t]*(\d+)[ \t]*\])?[ \t]*;[ \t]*(?://[ \t]*(\{[^\n]*\}))?"#)

    static func parseCombos(_ text: String) -> [ShaderComboDeclaration] {
        var result: [ShaderComboDeclaration] = []
        for match in comboPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let json = annotation(String(text[Range(match.range(at: 1), in: text)!])),
                  let name = json["combo"] as? String, !result.contains(where: { $0.name == name }) else { continue }
            let value = (json["default"] as? NSNumber)?.intValue ?? Int(json["default"] as? String ?? "") ?? 0
            result.append(ShaderComboDeclaration(name: name.uppercased(), defaultValue: value))
        }
        return result
    }

    static func parseUniforms(_ text: String) -> [ShaderUniformDeclaration] {
        var result: [ShaderUniformDeclaration] = []
        for match in uniformPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let group = { (i: Int) -> String? in Range(match.range(at: i), in: text).map { String(text[$0]) } }
            guard let type = group(1), let name = group(2), !result.contains(where: { $0.name == name }) else { continue }
            result.append(ShaderUniformDeclaration(type: type, name: name, arrayCount: group(3).flatMap(Int.init),
                                                   annotation: group(4).flatMap(annotation) ?? [:]))
        }
        return result
    }

    /// WE annotations are JSON, occasionally with trailing commas or a stray key.
    static func annotation(_ raw: String) -> [String: Any]? {
        if let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] {
            return object
        }
        return nil
    }
}
