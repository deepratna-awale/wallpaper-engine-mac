import Foundation

/// Rewrites a preprocessed vertex/fragment pair so its Metal translation has a fixed, predictable
/// interface:
/// - every loose uniform of both stages lives in one std140 block `WEUniforms` at buffer 0;
/// - `g_TextureN` is bound at texture/sampler N;
/// - varyings get the same location in both stages (assigned by name);
/// - vertex attributes get fixed locations (`a_Position` 0, `a_TexCoord` 1, ...).
enum ShaderPairRewriter {
    static let uniformBlockName = "WEUniforms"

    /// Locations for the vertex streams WE meshes provide; `ShaderVertexLayout` mirrors these.
    static let attributeLocations: [String: Int] = [
        "a_Position": 0, "a_PositionVec4": 0,
        "a_TexCoord": 1, "a_TexCoordVec4": 1,
        "a_Normal": 2, "a_Tangent4": 3, "a_Color": 4,
        "a_BlendIndices": 5, "a_BlendWeights": 6,
        "a_TexCoordVec4C1": 7, "a_TexCoordC2": 7,
        "a_TexCoordVec4C2": 8, "a_TexCoordVec3C2": 8,
        "a_TexCoordC3": 9, "a_TexCoordVec4C3": 9,
        "a_TexCoordC4": 10, "a_PositionC1": 11,
    ]

    struct Result {
        let vertex: String
        let fragment: String
        /// Uniform block members in declaration order (name, GLSL type, array count).
        let uniforms: [(name: String, type: String, arrayCount: Int?)]
        /// `g_TextureN` slots the pair samples.
        let textureSlots: [Int]
        /// Attribute name → location, for the attributes the vertex stage reads.
        let attributes: [String: Int]
    }

    private static let precision = #"(?:(?:lowp|mediump|highp)\s+)?"#
    private static let uniformPattern = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*uniform\s+"# + precision + #"(?!sampler)(\w+)\s+(\w+)\s*(?:\[\s*(\d+)\s*\])?\s*(?:=[^;]*)?;[ \t]*$"#)
    private static let samplerPattern = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*uniform\s+"# + precision + #"(sampler\w*)\s+(\w+)\s*;[ \t]*$"#)
    private static let varyingPattern = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*((?:flat|smooth|noperspective)\s+)?(in|out)\s+"# + precision + #"(\w+)\s+(\w+)\s*(?:\[\s*(\d+)\s*\])?\s*;[ \t]*$"#)

    static func rewrite(vertex: String, fragment: String) -> Result {
        // Uniforms: union of both stages, vertex first, so the block is identical in each.
        var members: [(name: String, type: String, arrayCount: Int?)] = []
        for text in [vertex, fragment] {
            for match in uniformPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let name = group(match, 2, text)!
                guard !members.contains(where: { $0.name == name }) else { continue }
                members.append((name, group(match, 1, text)!, group(match, 3, text).flatMap(Int.init)))
            }
        }

        // Varyings: vertex outputs and fragment inputs, located by name.
        struct Varying { let qualifier: String; let type: String; let name: String; let arrayCount: Int? }
        func varyings(_ text: String, direction: String) -> [Varying] {
            varyingPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                let name = group(match, 4, text)!
                guard group(match, 2, text) == direction, !name.hasPrefix("a_"), name != "out_FragColor" else { return nil }
                return Varying(qualifier: group(match, 1, text) ?? "", type: group(match, 3, text)!,
                               name: name, arrayCount: group(match, 5, text).flatMap(Int.init))
            }
        }
        let vertexOutputs = varyings(vertex, direction: "out")
        let fragmentInputs = varyings(fragment, direction: "in")
        var locations: [String: Int] = [:]
        var next = 0
        for varying in vertexOutputs + fragmentInputs where locations[varying.name] == nil {
            locations[varying.name] = next
            next += slotCount(type: varying.type) * (varying.arrayCount ?? 1)
        }
        // A fragment input the vertex stage never writes would fail pipeline creation.
        let missing = fragmentInputs.filter { input in !vertexOutputs.contains { $0.name == input.name } }
        // WE's HLSL linkage tolerates a varying declared with different vector sizes in the two
        // stages; Metal doesn't. The fragment stage reads the vertex stage's type and converts.
        var resized: [String: (vertexType: String, fragmentType: String)] = [:]
        for input in fragmentInputs where input.arrayCount == nil {
            guard let output = vertexOutputs.first(where: { $0.name == input.name }), output.arrayCount == nil,
                  output.type != input.type, vectorSize(output.type) != nil, vectorSize(input.type) != nil else { continue }
            resized[input.name] = (output.type, input.type)
        }

        let block = members.isEmpty ? "" : "layout(std140, binding = 0) uniform \(uniformBlockName) {\n"
            + members.map { "    \($0.type) \($0.name)\($0.arrayCount.map { "[\($0)]" } ?? "");\n" }.joined() + "};\n"
        var slots = Set<Int>()

        func decorate(_ text: String, stage: ShaderStage) -> String {
            var result = replace(uniformPattern, in: text) { _ in "" }
            var extraSampler = 16
            result = replace(samplerPattern, in: result) { match in
                let name = group(match, 2, result)!
                let slot: Int
                if name.hasPrefix("g_Texture"), let n = Int(name.dropFirst("g_Texture".count)) {
                    slot = n
                    slots.insert(n)
                } else {
                    slot = extraSampler
                    extraSampler += 1
                }
                return "layout(binding = \(slot)) uniform \(group(match, 1, result)!) \(name);"
            }
            // HLSL vertex inputs are ordinary parameters that a shader may assign to; GLSL inputs
            // are read-only, so a written attribute is copied into a global of the same name.
            var writtenAttributes: [String] = []
            result = replace(varyingPattern, in: result) { match in
                let name = group(match, 4, result)!
                let direction = group(match, 2, result)!
                let type = group(match, 3, result)!
                let array = group(match, 5, result).map { "[\($0)]" } ?? ""
                let qualifier = group(match, 1, result) ?? ""
                if stage == .vertex, direction == "in", name.hasPrefix("a_") {
                    let location = attributeLocations[name] ?? 15
                    if array.isEmpty, isAssigned(name, in: result) {
                        writtenAttributes.append(name)
                        return "layout(location = \(location)) in \(type) \(name)_weIn;\n\(type) \(name);"
                    }
                    return "layout(location = \(location)) in \(type) \(name)\(array);"
                }
                if name == "out_FragColor" { return "layout(location = 0) out \(type) \(name);" }
                guard let location = locations[name] else { return group(match, 0, result)! }
                if stage == .fragment, let types = resized[name] {
                    return "layout(location = \(location)) \(qualifier)in \(types.vertexType) \(name)_weVarying;\n\(type) \(name);"
                }
                return "layout(location = \(location)) \(qualifier)\(direction) \(type) \(name)\(array);"
            }
            if !writtenAttributes.isEmpty {
                result = insertAtMainEntry(result, writtenAttributes.map { "\($0) = \($0)_weIn;" }.joined(separator: " "))
            }
            if stage == .fragment, !resized.isEmpty {
                result = insertAtMainEntry(result, resized.sorted { $0.key < $1.key }.map { name, types in
                    "\(name) = \(convert("\(name)_weVarying", from: types.vertexType, to: types.fragmentType));"
                }.joined(separator: " "))
            }
            if stage == .vertex, !missing.isEmpty {
                result = insertAfterHeader(result, missing.map {
                    "layout(location = \(locations[$0.name]!)) \($0.qualifier)out \($0.type) \($0.name)\($0.arrayCount.map { "[\($0)]" } ?? "");"
                }.joined(separator: "\n") + "\n")
            }
            return insertAfterHeader(result, block)
        }

        let decoratedVertex = decorate(vertex, stage: .vertex)
        let decoratedFragment = decorate(fragment, stage: .fragment)
        var attributes: [String: Int] = [:]
        for match in varyingPattern.matches(in: vertex, range: NSRange(vertex.startIndex..., in: vertex)) {
            let name = group(match, 4, vertex)!
            if group(match, 2, vertex) == "in", name.hasPrefix("a_") { attributes[name] = attributeLocations[name] ?? 15 }
        }
        return Result(vertex: decoratedVertex, fragment: decoratedFragment, uniforms: members,
                      textureSlots: slots.sorted(), attributes: attributes)
    }

    /// Whether `name` (or a swizzle of it) is the target of `=` or a compound assignment.
    static func isAssigned(_ name: String, in text: String) -> Bool {
        NSRegularExpression.shader(#"(?<![\w.])"# + NSRegularExpression.escapedPattern(for: name)
                                   + #"\s*(?:\.\w+)?\s*[-+*/]?=(?!=)"#).matches(text)
    }

    /// Components of a float scalar/vector type; nil for anything else.
    static func vectorSize(_ type: String) -> Int? {
        switch type {
        case "float": return 1
        case "vec2": return 2
        case "vec3": return 3
        case "vec4": return 4
        default: return nil
        }
    }

    /// Truncates or zero-pads `expression` from one float vector type to another.
    static func convert(_ expression: String, from source: String, to target: String) -> String {
        let from = vectorSize(source)!, to = vectorSize(target)!
        if to < from { return "\(expression).\("xyzw".prefix(to))" }
        return "\(target)(\(expression)\(String(repeating: ", 0.0", count: to - from)))"
    }

    private static let mainPattern = try! NSRegularExpression(pattern: #"\bvoid\s+main\s*\(\s*(?:void)?\s*\)\s*\{"#)

    /// Inserts statements at the start of `main`.
    private static func insertAtMainEntry(_ text: String, _ statements: String) -> String {
        guard let match = mainPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return text }
        var result = text
        result.insert(contentsOf: "\n" + statements + "\n", at: range.upperBound)
        return result
    }

    /// Interface slots a varying of this type occupies.
    static func slotCount(type: String) -> Int {
        switch type {
        case "mat2": return 2
        case "mat3", "mat4x3": return 3
        case "mat4", "mat3x4": return 4
        default: return 1
        }
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, _ text: String) -> String? {
        Range(match.range(at: index), in: text).map { String(text[$0]) }
    }

    private static func replace(_ pattern: NSRegularExpression, in text: String,
                                with transform: (NSTextCheckingResult) -> String) -> String {
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            result.replaceSubrange(Range(match.range, in: result)!, with: transform(match))
        }
        return result
    }

    /// After `#version`/`#extension` and the preprocessor's `#line` markers at the top.
    private static func insertAfterHeader(_ text: String, _ insertion: String) -> String {
        guard !insertion.isEmpty else { return text }
        // Walks the header lines in place; `insertion` becomes a line of its own.
        let utf8 = text.utf8
        var lineStart = utf8.startIndex
        while true {
            let lineEnd = utf8[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? utf8.endIndex
            let line = text[lineStart..<lineEnd]
            guard line.hasPrefix("#version") || line.hasPrefix("#extension")
                    || line.utf8.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }) else { break }
            // Every line is header: the insertion becomes the last line.
            guard lineEnd < utf8.endIndex else { return text + "\n" + insertion }
            lineStart = utf8.index(after: lineEnd)
        }
        var result = text
        result.insert(contentsOf: insertion + "\n", at: lineStart)
        return result
    }
}
