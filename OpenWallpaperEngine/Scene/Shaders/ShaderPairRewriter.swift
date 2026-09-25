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
            result = replace(varyingPattern, in: result) { match in
                let name = group(match, 4, result)!
                let direction = group(match, 2, result)!
                let type = group(match, 3, result)!
                let array = group(match, 5, result).map { "[\($0)]" } ?? ""
                let qualifier = group(match, 1, result) ?? ""
                if stage == .vertex, direction == "in", name.hasPrefix("a_") {
                    return "layout(location = \(attributeLocations[name] ?? 15)) in \(type) \(name)\(array);"
                }
                if name == "out_FragColor" { return "layout(location = 0) out \(type) \(name);" }
                guard let location = locations[name] else { return group(match, 0, result)! }
                return "layout(location = \(location)) \(qualifier)\(direction) \(type) \(name)\(array);"
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
        var lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count, lines[index].hasPrefix("#version") || lines[index].hasPrefix("#extension")
                || lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            index += 1
        }
        lines.insert(insertion, at: index)
        return lines.joined(separator: "\n")
    }
}
