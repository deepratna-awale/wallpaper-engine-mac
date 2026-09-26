import Foundation

/// Names glslang rejects as identifiers in `#version 450` but WE's compiler accepts, because WE
/// compiles its dialect through HLSL: GLSL's words "reserved for future use" (`common`, `input`,
/// `filter`, `cast`, …) and GLSL-only keywords the dialect never uses as keywords (`buffer`,
/// `patch`, the image types, …).
///
/// The prelude renames each one a shader uses to `we_<name>` with a macro, so every use of it (a
/// local, a function, a uniform, a varying in both stages) changes the same way. The uniform block
/// is reflected back to WE's names with `originalName`, since material constants bind by name.
///
/// `sample` is renamed by the prelude for every shader, and the keywords HLSL shares (`shared`,
/// `volatile`, `precise`, `double`, …) can't be names in WE either, so neither is listed here.
enum GLSLReservedWords {
    static let words: Set<String> = {
        // GLSL 4.50 §3.6, as glslang's scanner rejects them.
        let reserved = [
            "common", "partition", "active", "asm", "class", "union", "enum", "typedef", "template",
            "this", "resource", "goto", "inline", "noinline", "public", "static", "extern", "external",
            "interface", "long", "short", "half", "fixed", "unsigned", "superp", "input", "output",
            "hvec2", "hvec3", "hvec4", "fvec2", "fvec3", "fvec4", "sampler3DRect", "filter", "sizeof",
            "cast", "namespace", "using",
        ]
        // Keywords of GLSL 4.50 and its extensions that HLSL doesn't have.
        let keywords = [
            "patch", "buffer", "coherent", "restrict", "readonly", "writeonly", "subroutine", "atomic_uint",
            "devicecoherent", "queuefamilycoherent", "workgroupcoherent", "subgroupcoherent",
            "shadercallcoherent", "nonprivate", "pervertexEXT", "pervertexNV", "tileImageEXT",
        ]
        let imageShapes = ["1D", "1DArray", "2D", "2DArray", "2DMS", "2DMSArray", "2DRect", "3D", "Buffer",
                           "Cube", "CubeArray"]
        let images = ["", "i", "u"].flatMap { prefix in imageShapes.map { "\(prefix)image\($0)" } }
        return Set(reserved + keywords + images)
    }()

    static let prefix = "we_"

    /// The name WE's shader used for `name`: `we_common` → `common`; any other name is itself.
    static func originalName(_ name: String) -> String {
        guard name.hasPrefix(prefix) else { return name }
        let original = String(name.dropFirst(prefix.count))
        return words.contains(original) ? original : name
    }

    /// The listed words `source` uses as identifiers in code, sorted. Comments and string literals
    /// (`#include "common.h"`) don't count.
    static func used(in source: String) -> [String] {
        words.intersection(codeIdentifiers(in: source)).sorted()
    }

    /// Every maximal run of ASCII identifier characters outside comments and string literals.
    static func codeIdentifiers(in source: String) -> Set<String> {
        var tokens = Set<String>()
        let bytes = Array(source.utf8)
        var index = 0
        var start: Int?
        func flush(at end: Int) {
            if let tokenStart = start {
                tokens.insert(String(decoding: bytes[tokenStart..<end], as: UTF8.self))
                start = nil
            }
        }
        while index < bytes.count {
            let byte = bytes[index]
            let next = index + 1 < bytes.count ? bytes[index + 1] : 0
            if byte == 0x2F, next == 0x2F { // `//` to the end of the line
                flush(at: index)
                while index < bytes.count, bytes[index] != 0x0A { index += 1 }
                continue
            }
            if byte == 0x2F, next == 0x2A { // `/*` to `*/`
                flush(at: index)
                index += 2
                while index < bytes.count, !(bytes[index] == 0x2A && index + 1 < bytes.count && bytes[index + 1] == 0x2F) {
                    index += 1
                }
                index += 2
                continue
            }
            if byte == 0x22 { // a string literal, which only `#include` and `#line` take
                flush(at: index)
                index += 1
                while index < bytes.count, bytes[index] != 0x22, bytes[index] != 0x0A { index += 1 }
                index += 1
                continue
            }
            let isWord = (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95
            if isWord {
                if start == nil { start = index }
            } else {
                flush(at: index)
            }
            index += 1
        }
        flush(at: min(index, bytes.count))
        return tokens
    }
}
