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
        let definitions = definedNames(in: source)
        let defined = definitions.macros.union(definitions.functions)
        lines.append(contentsOf: common.filter { line in
            macroName(line).map { !defined.contains($0) } ?? true
        })
        // A function named like a Metal built-in GLSL lacks (e.g. `log10`) becomes ambiguous
        // in MSL; rename the shader's own definition and every call to it.
        for name in metalOnlyBuiltins where definitions.functions.contains(name) && !definitions.macros.contains(name) {
            lines.append("#define \(name) we_\(name)")
        }
        // C++ keywords are valid GLSL names but not MSL ones (`vec2 or;`). Only names the shader
        // declares itself are renamed, never an interface name, which binds by name.
        for name in cppReservedWords.subtracting(definitions.macros).sorted() where declaresLocal(name, in: source) {
            lines.append("#define \(name) we_\(name)")
        }
        switch stage {
        case .vertex:
            lines.append(contentsOf: ["#define attribute in", "#define varying out"])
        case .fragment:
            lines.append(contentsOf: ["#define varying in", "#define gl_FragColor out_FragColor",
                                      "out vec4 out_FragColor;"])
        }
        lines.append(helperFunctions)
        if !defined.contains("texSample2D") {
            lines.append(sampleFunctions)
            // A bias only exists where derivatives do.
            if stage == .fragment {
                lines.append("vec4 texSample2D(sampler2D s, vec2 uv, float bias) { return texture(s, uv, bias); }")
            }
        }
        lines.append(conversionFunctions)
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

    /// C++ keywords (MSL is C++) that GLSL doesn't reserve. `not` is left out: it's a GLSL built-in.
    static let cppReservedWords: Set<String> = [
        "and", "or", "xor", "bitand", "bitor", "compl", "and_eq", "or_eq", "xor_eq", "not_eq",
        "template", "namespace", "this", "new", "delete", "operator", "class", "typename", "private",
        "public", "protected", "friend", "virtual", "register", "auto", "explicit", "mutable", "using",
        "typedef", "union", "enum", "extern", "static", "goto", "try", "catch", "throw", "sizeof",
        "alignas", "alignof", "decltype", "constexpr", "nullptr", "static_assert", "thread_local",
        "noexcept", "char", "short", "long", "signed", "unsigned", "wchar_t", "typeid", "export",
        "concept", "requires", "device", "constant", "thread", "threadgroup", "kernel", "vertex", "fragment",
    ]

    private static let interfacePattern = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*(?:uniform|varying|attribute|in|out)\b[^;]*;"#)

    /// Whether the shader declares `name` itself (a variable or function after a type), and not
    /// as a uniform, varying or attribute.
    static func declaresLocal(_ name: String, in source: String) -> Bool {
        guard source.range(of: #"\b\w+\s+"# + name + #"\s*[=;,()\[]"#, options: .regularExpression) != nil else { return false }
        let declarations = interfacePattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
        return !declarations.contains { match in
            (source as NSString).substring(with: match.range)
                .range(of: #"\b"# + name + #"\s*[;\[]"#, options: .regularExpression) != nil
        }
    }

    /// Names the shader `#define`s, and names it defines as functions.
    static func definedNames(in source: String) -> (macros: Set<String>, functions: Set<String>) {
        var macros = Set<String>(), functions = Set<String>()
        for match in definitionPattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            if let range = Range(match.range(at: 1), in: source) { macros.insert(String(source[range])) }
            if let range = Range(match.range(at: 2), in: source) { functions.insert(String(source[range])) }
        }
        return (macros, functions)
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
        // The preprocessor may respace the marker's tokens.
        let prelude = text.range(of: #"void\s+weEndOfPrelude\s*\(\s*\)\s*\{\s*\}"#, options: .regularExpression)
            .map { String(text[..<$0.upperBound]) } ?? ""
        var code = Array(text.dropFirst(prelude.count).utf16)
        code = packedArrayIndices(code)
        code = integerSubscripts(code)
        code = modulo(code)
        code = vectorOperandSizes(code)
        code = compoundAssignments(code)
        code = returnCasts(code)
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
            let left = Array(result[start..<percent]).trimmingSpaces()
            let right = Array(result[(percent + 1)..<end]).trimmingSpaces()
            result.replaceSubrange(start..<end, with: Array("weMod(".utf16) + left + Array(", ".utf16) + right + Array(")".utf16))
            search = start
        }
        return result
    }

    /// Start of the left operand of a multiplicative operator at `index`: postfix expressions
    /// joined by `*` and `/`, which bind as tightly and associate to the left.
    private static func operandStart(_ code: [UInt16], before index: Int) -> Int? {
        func postfixStart(endingAt end: Int) -> Int? { ShaderPrelude.postfixStart(code, endingAt: end) }
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

    /// End (exclusive) of an expression starting at `start`: the first `,`/`;` outside brackets.
    private static func expressionEnd(_ code: [UInt16], from start: Int) -> Int? {
        var nesting = 0
        var position = start
        while position < code.count {
            let character = code[position]
            if isOpening(character) { nesting += 1 }
            if isClosing(character) { nesting -= 1 }
            if nesting < 0 { return nil }
            if nesting == 0, character == ascii(",") || character == ascii(";") { return position }
            position += 1
        }
        return nil
    }

    private static let functionPattern = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*(float|int|uint|vec[234])\s+\w+\s*\([^;{}]*\)\s*\{"#)
    private static let returnPattern = try! NSRegularExpression(pattern: #"\breturn\b"#)

    /// `return e;` in a function returning `T` → `return weCast_T(e);`.
    private static func returnCasts(_ code: [UInt16]) -> [UInt16] {
        let text = String(decoding: code, as: UTF16.self) as NSString
        var edits: [(Int, String)] = []
        for function in functionPattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            let type = text.substring(with: function.range(at: 1))
            let open = function.range.location + function.range.length - 1
            guard let close = closing(code, from: open) else { continue }
            let body = NSRange(location: open, length: close - open)
            for statement in returnPattern.matches(in: text as String, range: body) {
                var start = statement.range.location + statement.range.length
                while start < close, isSpace(code[start]) { start += 1 }
                guard start < close, code[start] != ascii(";"), let end = expressionEnd(code, from: start),
                      code[end] == ascii(";") else { continue }
                edits.append((start, (isSpace(code[start - 1]) ? "" : " ") + "weCast_\(type)("))
                edits.append((end, ")"))
            }
        }
        return insert(edits, into: code)
    }

    private static let typedNamePattern = try! NSRegularExpression(pattern: #"\b(float|int|uint|vec[234]|bool|ivec[234]|uvec[234]|bvec[234]|mat[234])\s+(\w+)\s*[=;,)\[]"#)
    private static let compoundPattern = try! NSRegularExpression(pattern: #"(?<![\w.\]])(\w+)\s*([-+*/])=(?!=)"#)

    /// `x op= e` → `x = weCast_T(x op e)` for a local of float/int type `T` (HLSL converts the
    /// result, e.g. `int *= float`); for a float or float vector `x op= weCast_T(e)` (splat, truncate, bool).
    /// Only names declared with a single type in the shader are touched.
    /// Name → type for every name the shader declares with one type only.
    private static func declaredTypes(_ text: NSString) -> [String: String] {
        var types: [String: String] = [:]
        var ambiguous = Set<String>()
        for match in typedNamePattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            let type = text.substring(with: match.range(at: 1)), name = text.substring(with: match.range(at: 2))
            if let known = types[name], known != type { ambiguous.insert(name) }
            types[name] = type
        }
        return types.filter { !ambiguous.contains($0.key) }
    }

    private static func compoundAssignments(_ code: [UInt16]) -> [UInt16] {
        let text = String(decoding: code, as: UTF16.self) as NSString
        let whole = NSRange(location: 0, length: text.length)
        let types = declaredTypes(text)
        var edits: [(Int, String)] = []
        var removed: [Int] = []
        for match in compoundPattern.matches(in: text as String, range: whole) {
            let name = text.substring(with: match.range(at: 1))
            guard let type = types[name],
                  ["float", "int", "uint", "vec2", "vec3", "vec4"].contains(type) else { continue }
            var start = match.range.location + match.range.length
            while start < code.count, isSpace(code[start]) { start += 1 }
            guard let end = expressionEnd(code, from: start), code[end] == ascii(";") else { continue }
            if type.hasPrefix("vec") || type == "float" {
                edits.append((start, "weCast_\(type)("))
                edits.append((end, ")"))
            } else {
                // `x op= e` → `x = weCast_T(x op (e))`: the two operator characters are replaced.
                let operatorStart = match.range.location + match.range.length - 2
                removed += [operatorStart, operatorStart + 1]
                edits.append((operatorStart, "="))
                edits.append((start, "weCast_\(type)(\(name) \(text.substring(with: match.range(at: 2))) ("))
                edits.append((end, "))"))
            }
        }
        return insert(edits, into: code, removing: Set(removed))
    }

    /// Components of a vector operand when evident without a type checker: a declared name, a
    /// swizzle, or a `vecN(...)` constructor, optionally parenthesised. nil when unknown.
    private static func operandSize(_ operand: [UInt16], types: [String: String]) -> Int? {
        var text = String(decoding: operand, as: UTF16.self).trimmingCharacters(in: .whitespaces)
        while text.hasPrefix("("), let close = closing(Array(text.utf16), from: 0), close == text.utf16.count - 1 {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if let swizzle = text.range(of: #"\.[xyzwrgba]{1,4}$"#, options: .regularExpression) {
            return text.distance(from: swizzle.lowerBound, to: swizzle.upperBound) - 1
        }
        if text.range(of: #"^\w+$"#, options: .regularExpression) != nil {
            return types[text].flatMap { $0.hasPrefix("vec") ? dimension($0) : nil }
        }
        if let match = text.range(of: #"^vec[234]\("#, options: .regularExpression),
           let close = closing(Array(text.utf16), from: text.utf16.count - text[match.upperBound...].utf16.count - 1),
           close == text.utf16.count - 1 {
            return Int(String(text[text.index(text.startIndex, offsetBy: 3)]))
        }
        return nil
    }

    /// `a op b` with vectors of different sizes: HLSL truncates the wider one (`vec4 * vec2` is a
    /// `vec2`). Only operands whose size is evident are touched, and only when they are the
    /// operator's whole operands (not one factor of a product).
    private static func vectorOperandSizes(_ code: [UInt16]) -> [UInt16] {
        let types = declaredTypes(String(decoding: code, as: UTF16.self) as NSString)
        let operators: Set<UInt16> = [ascii("+"), ascii("-"), ascii("*"), ascii("/")]
        let multiplicative: Set<UInt16> = [ascii("*"), ascii("/")]
        var edits: [(Int, String)] = []
        for index in code.indices where operators.contains(code[index]) {
            guard index > 0, index + 1 < code.count, code[index + 1] != ascii("="), code[index + 1] != code[index],
                  code[index - 1] != code[index] else { continue }
            var leftEnd = index - 1
            while leftEnd >= 0, isSpace(code[leftEnd]) { leftEnd -= 1 }
            guard leftEnd >= 0, isIdentifier(code[leftEnd]) || code[leftEnd] == ascii(")") || code[leftEnd] == ascii("]"),
                  let leftStart = postfixStart(code, endingAt: leftEnd),
                  let rightEnd = operandEnd(code, after: index) else { continue }
            var before = leftStart - 1
            while before >= 0, isSpace(code[before]) { before -= 1 }
            var after = rightEnd
            while after < code.count, isSpace(code[after]) { after += 1 }
            // The left operand of `+`/`*` must not be the last factor of a longer product, nor the
            // right operand of `+`/`-` the first factor of one.
            if before >= 0, multiplicative.contains(code[before]) { continue }
            if !multiplicative.contains(code[index]), after < code.count, multiplicative.contains(code[after]) { continue }
            let left = Array(code[leftStart...leftEnd])
            let right = Array(code[(index + 1)..<rightEnd])
            guard let leftSize = operandSize(left, types: types), let rightSize = operandSize(right, types: types),
                  leftSize > 1, rightSize > 1, leftSize != rightSize else { continue }
            let smaller = swizzle(min(leftSize, rightSize))
            edits.append((leftSize > rightSize ? leftEnd + 1 : rightEnd, ".\(smaller)"))
        }
        return insert(edits, into: code)
    }

    /// Start of the postfix expression (name, call, index, member chain) ending at `end`.
    private static func postfixStart(_ code: [UInt16], endingAt end: Int) -> Int? {
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
    /// Insertions before the given offsets (in edit order at equal offsets), and removal of the
    /// characters at `removing`.
    private static func insert(_ edits: [(Int, String)], into code: [UInt16], removing: Set<Int> = []) -> [UInt16] {
        var byOffset: [Int: [UInt16]] = [:]
        for (offset, text) in edits { byOffset[offset, default: []] += Array(text.utf16) }
        var result: [UInt16] = []
        result.reserveCapacity(code.count + edits.count * 12)
        for index in 0...code.count {
            if let text = byOffset[index] { result += text }
            if index < code.count, !removing.contains(index) { result.append(code[index]) }
        }
        return result
    }
}

private extension Array where Element == UInt16 {
    func trimmingSpaces() -> [UInt16] {
        let isSpace: (UInt16) -> Bool = { $0 == 32 || $0 == 9 || $0 == 10 || $0 == 13 }
        guard let first = firstIndex(where: { !isSpace($0) }), let last = lastIndex(where: { !isSpace($0) }) else { return [] }
        return Array(self[first...last])
    }
}
