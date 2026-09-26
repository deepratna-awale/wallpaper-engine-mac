import XCTest
import Metal
@testable import OpenWallpaperEngine

/// Names GLSL reserves but WE's HLSL-backed compiler accepts (`float common;` in a workshop
/// FXAA, `vec4 input` in WE's own blend effect) translate, with interface names kept intact.
final class GLSLReservedWordsTests: XCTestCase {
    private let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil,
                                                     failureDirectory: nil)

    /// The list is exactly what it claims: glslang rejects each word as a name.
    func testGlslangRejectsEveryListedWord() throws {
        let compiler = InProcessShaderCompiler()
        for word in GLSLReservedWords.words.sorted() {
            let text = "#version 450\nlayout(location = 0) out vec4 color;\nvoid main() { float \(word) = 1.0; color = vec4(\(word)); }\n"
            XCTAssertThrowsError(try compiler.compileToMSL(text, stage: .fragment), word)
        }
    }

    /// Every listed word works as a local, a function and a parameter.
    func testEveryListedWordTranslatesAsALocalName() throws {
        let vertex = ShaderSource(stage: .vertex, path: "v", text: "void main() { gl_Position = vec4(0.0); }",
                                  combos: [], uniforms: [])
        for word in GLSLReservedWords.words.sorted() {
            let text = """
            float \(word)_f(float \(word)) { return \(word) * 2.0; }
            void main() { float \(word) = 1.0; gl_FragColor = vec4(\(word)_f(\(word))); }
            """
            let fragment = ShaderSource(stage: .fragment, path: "f", text: text, combos: [], uniforms: [])
            XCTAssertNoThrow(try translator.variant(vertex: vertex, fragment: fragment, combos: [:]), word)
        }
    }

    /// A uniform keeps WE's name in the block's layout, where material constants find it, and a
    /// varying links between the stages.
    func testInterfaceNamesStayBoundByWEsName() throws {
        let vertex = ShaderSource(stage: .vertex, path: "v", text: """
            attribute vec3 a_Position;
            uniform float filter;
            varying vec4 input;
            void main() { input = vec4(filter); gl_Position = vec4(a_Position, 1.0); }
            """, combos: [], uniforms: [])
        let fragment = ShaderSource(stage: .fragment, path: "f", text: """
            uniform float filter;
            uniform float g_Brightness;
            varying vec4 input;
            void main() { float common = filter * g_Brightness; gl_FragColor = input * common; }
            """, combos: [], uniforms: [])
        let variant = try translator.variant(vertex: vertex, fragment: fragment, combos: [:])
        let members = try XCTUnwrap(variant.uniforms?.members)
        XCTAssertEqual(Set(members.keys), ["filter", "g_Brightness"])
        XCTAssertEqual(members["filter"]?.name, "filter")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        XCTAssertNoThrow(try device.makeLibrary(source: variant.vertexMSL, options: nil))
        XCTAssertNoThrow(try device.makeLibrary(source: variant.fragmentMSL, options: nil))
    }

    /// WE's own blend effect names a local `input` when it writes alpha.
    func testBundledBlendTranslatesWhenWritingAlpha() throws {
        let loader = ShaderSourceLoader(roots: [ShaderVariantTests.weAssets])
        let path = "effects/blend/shaders/effects/blend"
        let vertex = try loader.load(path, stage: .vertex), fragment = try loader.load(path, stage: .fragment)
        XCTAssertEqual(fragment.preludeAnalysis.glslReservedNames, ["input"])
        let combos = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment,
                                                           overrides: [["WRITEALPHA": 1]], boundTextureSlots: [0, 1])
        XCTAssertNoThrow(try translator.variant(vertex: vertex, fragment: fragment, combos: combos))
    }

    /// Comments and string literals (`#include "common.h"`) are not names; a shader's own macro
    /// of the name is left to the preprocessor.
    func testOnlyNamesInCodeAreRenamed() {
        XCTAssertEqual(GLSLReservedWords.used(in: "#include \"common.h\"\n// input\n/* filter\n cast */ float x;"), [])
        XCTAssertEqual(GLSLReservedWords.used(in: "float common; /* x */ vec2 input;//\n"), ["common", "input"])
        let source = ShaderSource(stage: .fragment, path: "f", text: "#define filter 1.0\nfloat common = filter;",
                                  combos: [], uniforms: [])
        XCTAssertEqual(source.preludeAnalysis.glslReservedNames, ["common"])
        let prelude = ShaderPrelude.text(for: .fragment, combos: [:], analysis: source.preludeAnalysis)
        XCTAssertTrue(prelude.contains("#define common we_common\n"))
        XCTAssertFalse(prelude.contains("#define filter"))
    }

    func testOriginalNameUndoesOnlyTheReservedRename() {
        XCTAssertEqual(GLSLReservedWords.originalName("we_filter"), "filter")
        XCTAssertEqual(GLSLReservedWords.originalName("we_log10"), "we_log10")
        XCTAssertEqual(GLSLReservedWords.originalName("g_Texture0"), "g_Texture0")
    }
}
