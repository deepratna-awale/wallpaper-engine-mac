import Foundation

/// The dialect shim prepended to every WE shader before glslang preprocesses it.
///
/// WE writes GLSL with HLSL-isms (`mul`, `frac`, `saturate`, `CAST3`, `float3`, ...). Everything is
/// expressed as preprocessor macros, never text replacement, so identifiers such as `fract` or
/// `sample` are left alone. The mapping follows linux-wallpaperengine and wallpaper-scene-renderer.
enum ShaderPrelude {
    static func text(for stage: ShaderStage, combos: [String: Int]) -> String {
        var lines = ["#version 450"]
        // Resolved combos first so the shader's own `#ifndef X / #define X default` keeps them.
        for (name, value) in combos.sorted(by: { $0.key < $1.key }) {
            lines.append("#define \(name) \(value)")
        }
        lines.append(contentsOf: common)
        switch stage {
        case .vertex:
            lines.append(contentsOf: ["#define attribute in", "#define varying out"])
        case .fragment:
            lines.append(contentsOf: ["#define varying in", "#define gl_FragColor out_FragColor",
                                      "out vec4 out_FragColor;"])
        }
        lines.append(helperFunctions)
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
        "#define texSample2D texture",
        "#define texSample2DLod textureLod",
        "#define texSample2DGrad textureGrad",
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

    private static let truncatedSample = try! NSRegularExpression(
        pattern: #"(\b(vec3|vec2|float)\s+\w+\s*=\s*texture(?:Lod|Grad)?\([^;]*\))\s*;"#)

    /// HLSL truncates vectors on assignment; GLSL doesn't. WE relies on it mostly for a texture
    /// sample initialising a narrower variable, so those get the swizzle HLSL implies.
    static func fixupAfterPreprocess(_ text: String) -> String {
        var result = text
        for match in truncatedSample.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let whole = Range(match.range(at: 1), in: text)!
            let type = String(text[Range(match.range(at: 2), in: text)!])
            let swizzle = type == "vec3" ? ".rgb" : type == "vec2" ? ".rg" : ".r"
            result.replaceSubrange(Range(match.range, in: result)!, with: "\(text[whole])\(swizzle);")
        }
        return result
    }
}
