import Foundation

/// HLSL semantics WE's geometry stages rely on that GLSL lacks. WE compiles those stages as HLSL
/// (`point VS_OUTPUT IN[1]`, `TriangleStream<PS_INPUT>`), so they lean on its conversions and
/// scoping more than any other stage.
///
/// These run on one preprocessed stage on its own, where every name has one type: the implicit
/// conversions of `ShaderPrelude.applyImplicitConversions`, arguments converted to their
/// parameter's type, and loop bodies that redeclare the loop variable.
enum HLSLStageRewrites {
    /// All three, on a preprocessed stage; `signatures` are the functions it can call.
    static func apply(to text: String, signatures: [String: [Parameter]]) -> String {
        argumentCasts(ShaderPrelude.applyImplicitConversions(to: loopBodyScopes(text)), signatures: signatures)
    }

    struct Parameter: Equatable {
        /// `in`, `out`, `inout` or empty.
        let qualifier: String
        let type: String
    }

    private static let functionPattern = NSRegularExpression.shader(#"\b(\w+)\s+(\w+)\s*\(([^()]*)\)\s*\{"#)
    private static let parameterPattern = NSRegularExpression.shader(
        #"^\s*(?:(in|out|inout)\s+)?(?:const\s+)?(?:(?:lowp|mediump|highp)\s+)?(\w+)\s+\w+\s*(?:\[[^\]]*\])?\s*$"#)
    private static let keywords: Set<String> = ["if", "for", "while", "switch", "return", "else", "do"]

    /// Parameters of every function defined once in `text`; a name defined with different
    /// parameters (overloads, `#if` variants) is left out.
    static func functionSignatures(in text: String) -> [String: [Parameter]] {
        var result: [String: [Parameter]] = [:]
        var ambiguous = Set<String>()
        for match in functionPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let returnType = Range(match.range(at: 1), in: text).map({ String(text[$0]) }),
                  let name = Range(match.range(at: 2), in: text).map({ String(text[$0]) }),
                  let list = Range(match.range(at: 3), in: text).map({ String(text[$0]) }),
                  !keywords.contains(returnType), !keywords.contains(name) else { continue }
            var parameters: [Parameter] = []
            var valid = true
            for raw in list.split(separator: ",").map(String.init) where !raw.trimmingCharacters(in: .whitespaces).isEmpty
                && raw.trimmingCharacters(in: .whitespaces) != "void" {
                guard let parameter = parameterPattern.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                      let type = Range(parameter.range(at: 2), in: raw).map({ String(raw[$0]) }) else { valid = false; break }
                parameters.append(Parameter(qualifier: Range(parameter.range(at: 1), in: raw).map { String(raw[$0]) } ?? "",
                                            type: type))
            }
            guard valid else { ambiguous.insert(name); continue }
            if let known = result[name], known != parameters { ambiguous.insert(name) }
            result[name] = parameters
        }
        return result.filter { !ambiguous.contains($0.key) }
    }

    private static let convertibleTypes: Set<String> = ["float", "int", "uint", "vec2", "vec3", "vec4"]

    /// HLSL converts an argument to its parameter's type (a wider vector truncates, a scalar
    /// splats): each input argument of a scalar or vector parameter becomes `weCast_T(argument)`,
    /// an identity where the types already match.
    static func argumentCasts(_ text: String, signatures: [String: [Parameter]]) -> String {
        let casts = signatures.filter { $0.value.contains { convertibleTypes.contains($0.type) && $0.qualifier != "out" && $0.qualifier != "inout" } }
        guard !casts.isEmpty else { return text }
        let names = casts.keys.sorted().map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let call = NSRegularExpression.shader(#"(?<![\w.])("# + names + #")\s*\("#)
        var result = text
        for match in call.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let nameRange = Range(match.range(at: 1), in: result), let whole = Range(match.range, in: result) else { continue }
            // A definition (`vec3 name(`) is not a call.
            let before = result[..<nameRange.lowerBound].reversed().drop { $0 == " " || $0 == "\t" || $0 == "\n" }
            if let last = before.first, last.isLetter || last.isNumber || last == "_" { continue }
            let open = result.index(before: whole.upperBound)
            guard let close = matching(result, open: open), let parameters = casts[String(result[nameRange])] else { continue }
            let arguments = splitArguments(String(result[result.index(after: open)..<close]))
            guard arguments.count == parameters.count else { continue }
            let converted = zip(arguments, parameters).map { argument, parameter in
                convertibleTypes.contains(parameter.type) && parameter.qualifier != "out" && parameter.qualifier != "inout"
                    ? "weCast_\(parameter.type)(\(argument))" : argument
            }
            result.replaceSubrange(result.index(after: open)..<close, with: converted.joined(separator: ","))
        }
        return result
    }

    /// Top-level comma-separated arguments.
    private static func splitArguments(_ text: String) -> [String] {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var parts: [String] = []
        var depth = 0
        var current = ""
        for character in text {
            if "([{".contains(character) { depth += 1 }
            if ")]}".contains(character) { depth -= 1 }
            if character == ",", depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    private static let loopHeaderPattern = NSRegularExpression.shader(#"\bfor\s*\(\s*\w+\s+(\w+)\s*="#)

    /// `for (int s = …) { float s = …; … }`: the body's `s` becomes `s_weBody` from its
    /// declaration to the end of the body.
    static func loopBodyScopes(_ text: String) -> String {
        var result = text
        for match in loopHeaderPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let nameRange = Range(match.range(at: 1), in: result),
                  let headerRange = Range(match.range, in: result),
                  let headerOpen = result[headerRange].firstIndex(of: "("),
                  let headerClose = matching(result, open: headerOpen),
                  let bodyOpen = result[result.index(after: headerClose)...].firstIndex(where: { !$0.isWhitespace }),
                  result[bodyOpen] == "{", let bodyClose = matching(result, open: bodyOpen) else { continue }
            let name = String(result[nameRange])
            let body = String(result[result.index(after: bodyOpen)..<bodyClose])
            let declaration = NSRegularExpression.shader(
                #"\b(?:float|int|uint|bool|[iub]?vec[234]|mat[234])\s+"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#)
            guard let found = declaration.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                  let foundRange = Range(found.range, in: body) else { continue }
            let use = NSRegularExpression.shader(#"(?<![\w.])"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#)
            let tail = String(body[foundRange.lowerBound...])
            let renamed = use.stringByReplacingMatches(in: tail, range: NSRange(tail.startIndex..., in: tail),
                                                       withTemplate: NSRegularExpression.escapedTemplate(for: name + "_weBody"))
            result.replaceSubrange(result.index(after: bodyOpen)..<bodyClose, with: body[..<foundRange.lowerBound] + renamed)
        }
        return result
    }

    /// The bracket closing the one at `open` (`(`/`{`).
    private static func matching(_ text: String, open: String.Index) -> String.Index? {
        let opening = text[open]
        let closing: Character = opening == "(" ? ")" : "}"
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == opening { depth += 1 }
            if text[index] == closing {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

}
