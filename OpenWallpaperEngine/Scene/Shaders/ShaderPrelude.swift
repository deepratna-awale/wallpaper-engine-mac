import Foundation

/// The dialect shim prepended to every WE shader before glslang preprocesses it.
///
/// WE writes GLSL with HLSL-isms (`mul`, `frac`, `saturate`, `CAST3`, `float3`, ...). Names are
/// mapped with preprocessor macros and helper functions, never text replacement, so identifiers
/// such as `fract` or `sample` are left alone. The mapping follows linux-wallpaperengine and
/// wallpaper-scene-renderer. HLSL's implicit conversions, which no macro can express, are applied
/// to the preprocessed text by `fixupAfterPreprocess`.
enum ShaderPrelude {
    /// `source` is the shader the prelude goes in front of: a macro the shader defines itself (as a
    /// macro or a function, e.g. its own `M_PI` or `log10`) is left out, as WE has no such macro.
    static func text(for stage: ShaderStage, combos: [String: Int], source: String = "") -> String {
        var lines = ["#version 450"]
        // Resolved combos first so the shader's own `#ifndef X / #define X default` keeps them.
        for (name, value) in combos.sorted(by: { $0.key < $1.key }) {
            lines.append("#define \(name) \(value)")
        }
        let defined = definedNames(in: source)
        lines.append(contentsOf: common.filter { line in
            macroName(line).map { !defined.contains($0) } ?? true
        })
        // A function named like a Metal built-in GLSL lacks (e.g. `log10`) becomes ambiguous
        // in MSL; rename the shader's own definition and every call to it.
        for name in metalOnlyBuiltins where definesFunction(name, in: source) {
            lines.append("#define \(name) we_\(name)")
        }
        switch stage {
        case .vertex:
            lines.append(contentsOf: ["#define attribute in", "#define varying out"])
        case .fragment:
            lines.append(contentsOf: ["#define varying in", "#define gl_FragColor out_FragColor",
                                      "out vec4 out_FragColor;"])
        }
        lines.append(conversionFunctions)
        if !defined.contains("texSample2D") {
            lines.append(sampleFunctions)
            // Implicit-LOD sampling with a bias exists only in fragment shaders.
            if stage == .fragment { lines.append(fragmentSampleFunctions) }
        }
        lines.append(helperFunctions)
        // After every helper, so their own `mix` calls stay the built-in.
        if !defined.contains("mix") { lines.append("#define mix(a, b, t) weMix(a, b, t)") }
        lines.append(endMarker)
        return lines.joined(separator: "\n") + "\n"
    }

    private static let common = [
        "#define GLSL 1",
        "#define HLSL 0",
        "#define highp",
        "#define mediump",
        "#define lowp",
        "#define mul(x, y) ((y) * (x))",
        "#define frac(x) fract(x)",
        "#define lerp(x, y, a) mix(x, y, a)",
        "#define saturate(x) clamp(x, 0.0, 1.0)",
        "#define atan2(y, x) atan(y, x)",
        "#define fmod(x, y) ((x) - (y) * trunc((x) / (y)))",
        "#define log10(x) (log2(x) * 0.301029995663981)",
        "#define ddx(x) dFdx(x)",
        "#define ddy(x) dFdy(-(x))",
        "#define CAST2(x) (vec2(x))",
        "#define CAST3(x) (vec3(x))",
        "#define CAST4(x) (vec4(x))",
        "#define CAST3X3(x) (mat3(x))",
        "#define CASTF(x) (float(x))",
        "#define CASTI(x) (int(x))",
        "#define CASTU(x) (uint(x))",
        "#define float1 float",
        "#define float2 vec2",
        "#define float3 vec3",
        "#define float4 vec4",
        "#define int2 ivec2",
        "#define int3 ivec3",
        "#define int4 ivec4",
        // `sample` is a reserved word in GLSL 4.50 that WE shaders use as a variable name.
        "#define sample weSample",
        // common.h's constants, token-for-token, for shaders that use them without including it
        // (an identical redefinition is legal, a different one is an error).
        "#define M_PI 3.14159265359",
        "#define M_PI_HALF 1.57079632679",
        "#define M_PI_2 6.28318530718",
        "#define SQRT_2 1.41421356237",
        "#define SQRT_3 1.73205080756",
        // Engine feature switches the shaders test with `#if`; WE defines them per platform.
        "#ifndef HLSL_SM30",
        "#define HLSL_SM30 0",
        "#endif",
    ]

    private static func macroName(_ line: String) -> String? {
        guard line.hasPrefix("#define ") else { return nil }
        return line.dropFirst("#define ".count).prefix { $0.isLetter || $0.isNumber || $0 == "_" }.description
    }

    private static let definitionPattern = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*#[ \t]*define[ \t]+(\w+)|\b\w+[ \t]+(\w+)[ \t]*\([^;{}()]*\)\s*\{"#)

    /// Built-in in the Metal standard library but not in GLSL, so a shader may define its own.
    static let metalOnlyBuiltins = ["log10", "fmod", "rsqrt", "saturate", "fract2", "powr", "select", "median3"]

    static func definesFunction(_ name: String, in source: String) -> Bool {
        source.range(of: #"\b\w+\s+"# + name + #"\s*\([^;{]*\)\s*\{"#, options: .regularExpression) != nil
    }

    /// Names the shader `#define`s or defines as a function.
    static func definedNames(in source: String) -> Set<String> {
        var names = Set<String>()
        for match in definitionPattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            for index in 1...2 {
                if let range = Range(match.range(at: index), in: source) { names.insert(String(source[range])) }
            }
        }
        return names
    }

    /// HLSL accepts scalar/vector mixes that GLSL overload resolution rejects. Declaring any
    /// overload of a built-in also stops glslang converting int arguments for the built-in itself,
    /// so the int forms WE shaders use (`pow(x, 4)`, `max(0, x)`) are declared too.
    private static let helperFunctions = """
    vec2 rotateVec2(vec4 v, float angle) { float s = sin(angle); float c = cos(angle); return vec2(v.x * c - v.y * s, v.x * s + v.y * c); }
    vec2 pow(vec2 v, float e) { return pow(v, vec2(e)); }
    vec3 pow(vec3 v, float e) { return pow(v, vec3(e)); }
    vec4 pow(vec4 v, float e) { return pow(v, vec4(e)); }
    float pow(float v, int e) { return pow(v, float(e)); }
    vec2 pow(vec2 v, int e) { return pow(v, vec2(e)); }
    vec3 pow(vec3 v, int e) { return pow(v, vec3(e)); }
    vec4 pow(vec4 v, int e) { return pow(v, vec4(e)); }
    vec2 max(float a, vec2 b) { return max(vec2(a), b); }
    vec3 max(float a, vec3 b) { return max(vec3(a), b); }
    vec4 max(float a, vec4 b) { return max(vec4(a), b); }
    float max(int a, float b) { return max(float(a), b); }
    float max(float a, int b) { return max(a, float(b)); }
    vec2 max(int a, vec2 b) { return max(vec2(a), b); }
    vec3 max(int a, vec3 b) { return max(vec3(a), b); }
    vec4 max(int a, vec4 b) { return max(vec4(a), b); }
    """

    /// WE's sampling functions. HLSL truncates a wider coordinate to the sampler's two, so a
    /// `vec3`/`vec4` coordinate samples with its `xy`.
    private static let fragmentSampleFunctions =
        "vec4 texSample2D(sampler2D s, vec2 uv, float bias) { return texture(s, uv, bias); }"

    private static let sampleFunctions = """
    vec4 texSample2D(sampler2D s, vec2 uv) { return texture(s, uv); }
    vec4 texSample2D(sampler2D s, vec3 uv) { return texture(s, uv.xy); }
    vec4 texSample2D(sampler2D s, vec4 uv) { return texture(s, uv.xy); }
    vec4 texSample2DLod(sampler2D s, vec2 uv, float lod) { return textureLod(s, uv, lod); }
    vec4 texSample2DLod(sampler2D s, vec3 uv, float lod) { return textureLod(s, uv.xy, lod); }
    vec4 texSample2DLod(sampler2D s, vec4 uv, float lod) { return textureLod(s, uv.xy, lod); }
    vec4 texSample2DGrad(sampler2D s, vec2 uv, vec2 dx, vec2 dy) { return textureGrad(s, uv, dx, dy); }
    """

    /// HLSL's implicit conversions, applied to preprocessed text (see the extension below).
    static func fixupAfterPreprocess(_ text: String) -> String {
        applyImplicitConversions(to: text)
    }
}

// MARK: - HLSL implicit conversions

/// WE compiles its GLSL through HLSL, which converts implicitly where GLSL won't: a scalar splats to
/// a vector, a wider vector truncates, a float truncates to an int, `%` works on floats and arrays
/// take float indices. These rewrites make each such spot explicit, with HLSL's semantics, and are
/// identities wherever the shader was already valid GLSL.
extension ShaderPrelude {
    private static let floatVectors = ["vec2", "vec3", "vec4"]

    private static func dimension(_ type: String) -> Int {
        type.hasPrefix("vec") ? Int(String(type.last!))! : 1
    }

    private static func swizzle(_ count: Int) -> String { String("xyzw".prefix(count)) }

    /// - `weCast_T(x)`: initialising a `T` from `x`.
    /// - `weMod(x, y)`: `%`, which HLSL also defines for floats (as `fmod`).
    /// - `weMix(a, b, t)`: `mix`/`lerp` whose operands differ in size (the wider ones truncate).
    static let conversionFunctions: String = {
        var lines: [String] = []
        let sources = ["float", "int", "uint", "bool"] + floatVectors
        for target in ["float", "int", "uint"] {
            for source in sources {
                lines.append("\(target) weCast_\(target)(\(source) x) { return \(target)(\(dimension(source) > 1 ? "x.x" : "x")); }")
            }
        }
        for target in floatVectors {
            let n = dimension(target)
            for source in sources {
                let m = dimension(source)
                if m == 1 {
                    lines.append("\(target) weCast_\(target)(\(source) x) { return \(target)(float(x)); }")
                } else if m >= n {
                    lines.append("\(target) weCast_\(target)(\(source) x) { return x.\(swizzle(n)); }")
                }
            }
        }

        lines.append("float weMod(float x, float y) { return x - y * trunc(x / y); }")
        for vector in floatVectors {
            lines.append("\(vector) weMod(\(vector) x, \(vector) y) { return x - y * trunc(x / y); }")
            lines.append("\(vector) weMod(\(vector) x, float y) { return x - y * trunc(x / y); }")
        }
        lines += ["int weMod(int x, int y) { return x - y * (x / y); }",
                  "uint weMod(uint x, uint y) { return x - y * (x / y); }",
                  "uint weMod(uint x, int y) { return x - uint(y) * (x / uint(y)); }",
                  "uint weMod(int x, uint y) { return uint(x) - y * (uint(x) / y); }"]
        for n in 2...4 {
            lines.append("ivec\(n) weMod(ivec\(n) x, ivec\(n) y) { return x - y * (x / y); }")
            lines.append("ivec\(n) weMod(ivec\(n) x, int y) { return x - y * (x / y); }")
        }

        let mixTypes = ["float"] + floatVectors
        for a in mixTypes {
            for b in mixTypes {
                for t in mixTypes {
                    let n = [a, b, t].map(dimension).filter { $0 > 1 }.min() ?? 1
                    let result = n == 1 ? "float" : "vec\(n)"
                    func fit(_ name: String, _ type: String, keepScalar: Bool) -> String {
                        let m = dimension(type)
                        if m == 1 { return n == 1 || keepScalar ? name : "\(result)(\(name))" }
                        return m == n ? name : "\(name).\(swizzle(n))"
                    }
                    lines.append("\(result) weMix(\(a) a, \(b) b, \(t) t) { return mix(\(fit("a", a, keepScalar: false)), "
                                 + "\(fit("b", b, keepScalar: false)), \(fit("t", t, keepScalar: true))); }")
                }
            }
        }
        lines.append("float weMix(float a, float b, bool t) { return mix(a, b, t); }")
        for n in 2...4 { lines.append("vec\(n) weMix(vec\(n) a, vec\(n) b, bvec\(n) t) { return mix(a, b, t); }") }
        return lines.joined(separator: "\n")
    }()

    /// Ends the prelude in preprocessed text; the rewrites apply only to the shader after it.
    static let endMarker = "void weEndOfPrelude() {}"

    static func applyImplicitConversions(to text: String) -> String {
        let prelude = text.range(of: endMarker).map { String(text[..<$0.upperBound]) } ?? ""
        var code = Array(text.dropFirst(prelude.count).utf16)
        code = packedArrayIndices(code)
        code = integerSubscripts(code)
        code = modulo(code)
        code = declarationCasts(code)
        return prelude + String(decoding: code, as: UTF16.self)
    }

    // MARK: Rewrites

    private static let floatArrayPattern = try! NSRegularExpression(pattern: #"\bfloat\s+(\w+)\s*\[\s*(\d+)\s*\]"#)

    /// `float x[64]` is a `float4[16]` in WE's HLSL, and some shaders index it that way:
    /// `x[i][j]` → `x[i * 4 + j]`.
    private static func packedArrayIndices(_ code: [UInt16]) -> [UInt16] {
        let text = String(decoding: code, as: UTF16.self) as NSString
        var names = Set<String>()
        for match in floatArrayPattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            if let count = Int(text.substring(with: match.range(at: 2))), count % 4 == 0 {
                names.insert(text.substring(with: match.range(at: 1)))
            }
        }
        var result = code
        for name in names.sorted() {
            guard let use = try? NSRegularExpression(pattern: #"\b"# + name + #"\s*\["#) else { continue } // names are \w+
            let current = String(decoding: result, as: UTF16.self)
            for match in use.matches(in: current, range: NSRange(location: 0, length: result.count)).reversed() {
                let open = match.range.location + match.range.length - 1
                guard let close = closing(result, from: open) else { continue }
                var second = close + 1
                while second < result.count, isSpace(result[second]) { second += 1 }
                guard second < result.count, result[second] == ascii("["),
                      let secondClose = closing(result, from: second) else { continue }
                let outer = Array(result[(open + 1)..<close])
                let inner = Array(result[(second + 1)..<secondClose])
                let replacement = Array("[int(".utf16) + outer + Array(") * 4 + int(".utf16) + inner + Array(")]".utf16)
                result.replaceSubrange(open...secondClose, with: replacement)
            }
        }
        return result
    }

    private static let declarationTypes: Set<String> = [
        "float", "int", "uint", "bool", "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4",
        "uvec2", "uvec3", "uvec4", "bvec2", "bvec3", "bvec4", "mat2", "mat3", "mat4",
    ]

    /// HLSL truncates a float index: `a[i]` → `a[int(i)]` (integer literals and array sizes stay).
    private static func integerSubscripts(_ code: [UInt16]) -> [UInt16] {
        var edits: [(Int, String)] = []
        for open in code.indices where code[open] == ascii("[") {
            guard let close = closing(code, from: open) else { continue }
            let content = code[(open + 1)..<close].filter { !isSpace($0) }
            guard !content.isEmpty, !content.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { continue }
            // `float name[SIZE]`: a declaration, whose size must stay a constant expression.
            var index = open - 1
            while index >= 0, isSpace(code[index]) { index -= 1 }
            let nameEnd = index + 1
            while index >= 0, isIdentifier(code[index]) { index -= 1 }
            if nameEnd > index + 1 {
                while index >= 0, isSpace(code[index]) { index -= 1 }
                let typeEnd = index + 1
                while index >= 0, isIdentifier(code[index]) { index -= 1 }
                let type = String(decoding: code[(index + 1)..<typeEnd], as: UTF16.self)
                if declarationTypes.contains(type) { continue }
            }
            edits.append((open + 1, "int("))
            edits.append((close, ")"))
        }
        return insert(edits, into: code)
    }

    /// `x % y` → `weMod(x, y)`, which keeps `%` for integers and is `fmod` for floats.
    private static func modulo(_ code: [UInt16]) -> [UInt16] {
        var result = code
        var search = 0
        while search < result.count, let percent = result[search...].firstIndex(of: ascii("%")) {
            guard percent + 1 < result.count, result[percent + 1] != ascii("="),
                  let start = operandStart(result, before: percent),
                  let end = operandEnd(result, after: percent) else {
                search = percent + 1
                continue
            }
            let left = Array(result[start..<percent])
            let right = Array(result[(percent + 1)..<end])
            result.replaceSubrange(start..<end, with: Array("weMod(".utf16) + left + Array(", ".utf16) + right + Array(")".utf16))
            search = start
        }
        return result
    }

    /// Start of the left operand of a multiplicative operator at `index`: postfix expressions
    /// joined by `*` and `/`, which bind as tightly and associate to the left.
    private static func operandStart(_ code: [UInt16], before index: Int) -> Int? {
        func postfixStart(endingAt end: Int) -> Int? {
            var position = end
            var start: Int?
            while position >= 0 {
                let character = code[position]
                if isClosing(character) && character != ascii("}") {
                    guard let open = opening(code, from: position) else { return nil }
                    start = open
                    position = open - 1
                } else if isIdentifier(character) || character == ascii(".") {
                    start = position
                    position -= 1
                } else {
                    break
                }
            }
            return start
        }
        var position = index - 1
        while position >= 0, isSpace(code[position]) { position -= 1 }
        guard position >= 0, var start = postfixStart(endingAt: position) else { return nil }
        while true {
            var operatorIndex = start - 1
            while operatorIndex >= 0, isSpace(code[operatorIndex]) { operatorIndex -= 1 }
            guard operatorIndex > 0, code[operatorIndex] == ascii("*") || code[operatorIndex] == ascii("/") else { break }
            var previous = operatorIndex - 1
            while previous >= 0, isSpace(code[previous]) { previous -= 1 }
            guard previous >= 0, let earlier = postfixStart(endingAt: previous) else { break }
            start = earlier
        }
        return start
    }

    /// End (exclusive) of the right operand of `%` at `index`: one unary/postfix expression.
    private static func operandEnd(_ code: [UInt16], after index: Int) -> Int? {
        var position = index + 1
        while position < code.count, isSpace(code[position]) { position += 1 }
        if position < code.count, [ascii("-"), ascii("+"), ascii("!")].contains(code[position]) {
            position += 1
            while position < code.count, isSpace(code[position]) { position += 1 }
        }
        var end: Int?
        while position < code.count {
            let character = code[position]
            if character == ascii("(") || character == ascii("[") {
                guard let close = closing(code, from: position) else { return nil }
                position = close + 1
                end = position
            } else if isIdentifier(character) || character == ascii(".") {
                position += 1
                end = position
            } else {
                break
            }
        }
        return end
    }

    private static let declarationPattern = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[;{}(]))\s*(float|int|uint|vec[234])\s+\w+\s*=(?!=)"#, options: [.anchorsMatchLines])

    /// `T x = e;` in a function body → `T x = weCast_T(e);` (each declarator of a list).
    private static func declarationCasts(_ code: [UInt16]) -> [UInt16] {
        var depth = [Int](repeating: 0, count: code.count + 1)
        for (index, character) in code.enumerated() {
            depth[index + 1] = depth[index] + (character == ascii("{") ? 1 : character == ascii("}") ? -1 : 0)
        }
        let text = String(decoding: code, as: UTF16.self) as NSString
        var edits: [(Int, String)] = []
        for match in declarationPattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            guard depth[match.range.location] > 0 else { continue }
            let type = text.substring(with: match.range(at: 1))
            var position = match.range.location + match.range.length
            declarators: while true {
                while position < code.count, isSpace(code[position]) { position += 1 }
                let start = position
                var nesting = 0
                while position < code.count {
                    let character = code[position]
                    if isOpening(character) { nesting += 1 }
                    if isClosing(character) { nesting -= 1 }
                    if nesting < 0 || (nesting == 0 && (character == ascii(",") || character == ascii(";"))) { break }
                    position += 1
                }
                guard position < code.count, nesting == 0, position > start else { break }
                edits.append((start, "weCast_\(type)("))
                edits.append((position, ")"))
                guard code[position] == ascii(",") else { break }
                // Next declarator: `, name = e` gets the same treatment; `, name` has no initializer.
                while true {
                    position += 1
                    while position < code.count, isSpace(code[position]) { position += 1 }
                    guard position < code.count, isIdentifier(code[position]) else { break declarators }
                    while position < code.count, isIdentifier(code[position]) { position += 1 }
                    while position < code.count, isSpace(code[position]) { position += 1 }
                    guard position < code.count else { break declarators }
                    if code[position] == ascii("="), position + 1 < code.count, code[position + 1] != ascii("=") {
                        position += 1
                        continue declarators
                    }
                    guard code[position] == ascii(",") else { break declarators }
                }
            }
        }
        return insert(edits, into: code)
    }

    // MARK: Scanning

    private static func ascii(_ character: Character) -> UInt16 { UInt16(character.asciiValue!) }

    private static func isIdentifier(_ c: UInt16) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
    }

    private static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
    private static func isOpening(_ c: UInt16) -> Bool { c == 40 || c == 91 || c == 123 }
    private static func isClosing(_ c: UInt16) -> Bool { c == 41 || c == 93 || c == 125 }

    /// The bracket closing the one at `open`.
    private static func closing(_ code: [UInt16], from open: Int) -> Int? {
        var depth = 0
        for index in open..<code.count {
            if isOpening(code[index]) { depth += 1 }
            if isClosing(code[index]) {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    /// The bracket opening the one closing at `close`.
    private static func opening(_ code: [UInt16], from close: Int) -> Int? {
        var depth = 0
        for index in stride(from: close, through: 0, by: -1) {
            if isClosing(code[index]) { depth += 1 }
            if isOpening(code[index]) {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    /// Applies insertions; at equal offsets, later edits land first so earlier ones end up outside.
    private static func insert(_ edits: [(Int, String)], into code: [UInt16]) -> [UInt16] {
        var result = code
        let ordered = edits.enumerated().sorted { ($0.element.0, $0.offset) > ($1.element.0, $1.offset) }
        for (_, edit) in ordered {
            result.insert(contentsOf: Array(edit.1.utf16), at: edit.0)
        }
        return result
    }
}
