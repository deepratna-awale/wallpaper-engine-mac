import XCTest
import Metal
@testable import OpenWallpaperEngine

final class ShaderVariantTests: XCTestCase {
    /// The WE assets shipped in the app bundle, so tests cover what users get without a WE install.
    static let weAssets = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Vendor/we-assets")

    private var translator: ShaderVariantTranslator!
    private var cache: URL!

    override func setUpWithError() throws {
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-variants-\(UUID().uuidString)")
        translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache)
    }

    override func tearDownWithError() throws {
        if let cache { try? FileManager.default.removeItem(at: cache) }
    }

    /// Builds a render pipeline the way the renderer will: vertex descriptor from the function's own
    /// attributes, streams in buffer 30.
    static func makePipeline(_ variant: TranslatedShaderVariant, device: MTLDevice) throws -> MTLRenderPipelineState {
        let vertexLibrary = try device.makeLibrary(source: variant.vertexMSL, options: nil)
        let fragmentLibrary = try device.makeLibrary(source: variant.fragmentMSL, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexLibrary.makeFunction(name: "main0")
        descriptor.fragmentFunction = fragmentLibrary.makeFunction(name: "main0")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let vertexDescriptor = MTLVertexDescriptor()
        for attribute in descriptor.vertexFunction?.vertexAttributes ?? [] where attribute.isActive {
            let index = attribute.attributeIndex
            vertexDescriptor.attributes[index].format = vertexFormat(attribute.attributeType)
            vertexDescriptor.attributes[index].offset = 0
            vertexDescriptor.attributes[index].bufferIndex = 30 - index
            vertexDescriptor.layouts[30 - index].stride = 16
        }
        descriptor.vertexDescriptor = vertexDescriptor
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    static func vertexFormat(_ type: MTLDataType) -> MTLVertexFormat {
        switch type {
        case .float: return .float
        case .float2: return .float2
        case .float3: return .float3
        case .uint4: return .uint4
        case .int4: return .int4
        default: return .float4
        }
    }

    func testFixtureIdiomsTranslateAndBuildPipeline() throws {
        let loader = ShaderSourceLoader(roots: [Fixtures.url("ShaderAssets")])
        let vertex = try loader.load("effects/test/shaders/effects/test", stage: .vertex)
        let fragment = try loader.load("effects/test/shaders/effects/test", stage: .fragment)
        let combos = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment, overrides: [], boundTextureSlots: [0])
        let variant = try translator.variant(vertex: vertex, fragment: fragment, combos: combos)
        XCTAssertEqual(variant.textureSlots, [0])
        XCTAssertEqual(variant.attributes["a_Position"], 0)
        XCTAssertNotNil(variant.uniforms?.members["g_ModelViewProjectionMatrix"])
        XCTAssertNoThrow(try Self.makePipeline(variant, device: try XCTUnwrap(MTLCreateSystemDefaultDevice())))
    }

    // MARK: - Dialect (M8): each case below comes from a library wallpaper that failed to translate.

    /// Translates `effects/dialect/shaders/effects/<name>` and builds its pipeline.
    private func translateDialectFixture(_ name: String) throws -> TranslatedShaderVariant {
        let loader = ShaderSourceLoader(roots: [Fixtures.url("ShaderAssets")])
        let path = "effects/dialect/shaders/effects/\(name)"
        let vertex = try loader.load(path, stage: .vertex)
        let fragment = try loader.load(path, stage: .fragment)
        let combos = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment, overrides: [], boundTextureSlots: [0])
        let variant = try translator.variant(vertex: vertex, fragment: fragment, combos: combos)
        XCTAssertNoThrow(try Self.makePipeline(variant, device: try XCTUnwrap(MTLCreateSystemDefaultDevice())))
        return variant
    }

    /// Scalar splat, vector truncation, float→int, float `%`, float and packed-float4 array
    /// indices, `mix` of different sizes, a `vec4` sampling coordinate.
    func testHLSLImplicitConversionsTranslate() throws {
        _ = try translateDialectFixture("conversions")
    }

    func testDeclarationsGetHLSLInitialiserConversions() {
        let out = ShaderPrelude.fixupAfterPreprocess("void main() {\n vec2 a = 0.0, b, c = d.xyz;\n for (int i = f; i < 3; i++) {}\n}")
        XCTAssertTrue(out.contains("vec2 a = weCast_vec2(0.0), b, c = weCast_vec2(d.xyz);"), out)
        XCTAssertTrue(out.contains("for (int i = weCast_int(f);"), out)
        let global = "const vec3 k = vec3(1.0);\nvec2 g = vec2(0.0);\n"
        XCTAssertEqual(ShaderPrelude.fixupAfterPreprocess(global), global, "globals and consts must stay constant expressions")
    }

    func testModuloAndSubscriptsFollowHLSL() {
        let out = ShaderPrelude.fixupAfterPreprocess("void main() { x = a * b.y % 4 + (c + 1) % d[2]; y = s[i / 4]; z = s[3]; }")
        XCTAssertTrue(out.contains("weMod(a * b.y, 4) + weMod((c + 1), d[2])"), out)
        XCTAssertTrue(out.contains("s[int(i / 4)]"), out)
        XCTAssertTrue(out.contains("z = s[3]"), out)
        let packed = ShaderPrelude.fixupAfterPreprocess("uniform float g[64];\nvoid main() { v = g[i / 4][j]; }")
        XCTAssertTrue(packed.contains("g[int(int(i / 4) * 4 + int(j))]"), packed)
        XCTAssertTrue(packed.contains("uniform float g[64];"), packed)
    }

    /// HLSL converts a scalar `?:` condition to bool; `mask = INVERT ? 1 - mask : mask` with the
    /// combo preprocessed to `0` is a sharpen workshop effect.
    func testTernaryConditionsBecomeBool() {
        let out = ShaderPrelude.fixupAfterPreprocess(
            "void main() { m = 0 ? 1 - m : m; n = f(a == b ? x : y, (k) ? p : q ? r : s); o += t >= 1.0 ? 1.0 : 0.0; }")
        XCTAssertTrue(out.contains("m = bool(0) ? 1 - m : m;"), out)
        XCTAssertTrue(out.contains("f(bool(a == b) ? x : y, bool((k)) ? p : bool(q) ? r : s)"), out)
        XCTAssertTrue(out.contains("bool(t >= 1.0) ? 1.0 : 0.0"), out)
        let returned = ShaderPrelude.fixupAfterPreprocess("float g(int c) { return c ? 1.0 : 0.0; }")
        XCTAssertTrue(returned.contains("bool(c) ? 1.0 : 0.0"), returned)
    }

    /// A shader's own `M_PI`/`log10` replace the prelude's instead of clashing with them.
    func testShaderDefinitionsOverridePreludeMacros() throws {
        let prelude = ShaderPrelude.text(for: .fragment, combos: [:], source: "#define M_PI 3.14\nfloat log10(float x) { return x; }")
        XCTAssertFalse(prelude.contains("#define M_PI "))
        XCTAssertFalse(prelude.contains("#define log10(x)"))
        XCTAssertTrue(prelude.contains("#define log10 we_log10"), "clear of metal::log10")
        XCTAssertTrue(prelude.contains("#define M_PI_2 "))
        _ = try translateDialectFixture("redefines")
    }

    func testReturnsAndCompoundAssignmentsConvertLikeHLSL() {
        let out = ShaderPrelude.fixupAfterPreprocess("""
        vec3 f(vec2 uv) {
         vec4 col = vec4(uv, 0.0, 1.0);
         return col;
        }
        void main() {
         int bar = 1; bool left = true; float level = 1.0; vec2 uv = vec2(0.0);
         bar *= level * 0.5; level *= left; uv += 1.0; uv.x -= 2.0;
        }
        """)
        XCTAssertTrue(out.contains("return weCast_vec3(col);"), out)
        XCTAssertTrue(out.contains("bar = weCast_int(bar * (level * 0.5));"), out)
        XCTAssertTrue(out.contains("level *= weCast_float(left);"), out)
        XCTAssertTrue(out.contains("uv += weCast_vec2(1.0);"), out)
        XCTAssertTrue(out.contains("uv.x -= 2.0;"), out)
    }

    /// `vec4 * vec2` is a `vec2` in HLSL; only whole operands of evident size are truncated.
    func testMismatchedVectorOperandsTruncateTheWiderOne() {
        let out = ShaderPrelude.fixupAfterPreprocess("""
        uniform vec2 scale; in vec3 v_uv; uniform float u;
        void main() {
         vec4 p = vec4(1.0);
         vec2 a = p * scale * 0.5; vec2 b = abs(v_uv - (vec2(u))); vec4 c = p * u + p; vec2 d = p.xy * scale;
        }
        """)
        XCTAssertTrue(out.contains("p.xy * scale * 0.5"), out)
        XCTAssertTrue(out.contains("v_uv.xy - (vec2(u))"), out)
        XCTAssertTrue(out.contains("p * u + p)"), out)
        XCTAssertTrue(out.contains("p.xy * scale)"), out)
    }

    /// A product is one operand of `+`/`-`, sized by its narrowest vector factor: a workshop FXAA
    /// samples at `v_TexCoord + dir * (0.33333 - 0.5)` with a `vec4` texcoord and a `vec2` dir.
    func testAProductIsSizedAsOneOperandOfASum() {
        let out = ShaderPrelude.fixupAfterPreprocess("""
        in vec4 v_TexCoord; uniform float u;
        void main() {
         vec2 dir = vec2(1.0);
         vec2 a = v_TexCoord + dir * (0.33333 - 0.5); vec2 b = v_TexCoord - dir * - 0.5 * u;
         vec2 c = dir * 2.0 + v_TexCoord; vec2 d = dir + v_TexCoord * 2.0; vec4 e = v_TexCoord + v_TexCoord * u;
         vec2 f = dir + v_TexCoord * g(1.0);
        }
        """)
        XCTAssertTrue(out.contains("v_TexCoord.xy + dir * (0.33333 - 0.5)"), out)
        XCTAssertTrue(out.contains("v_TexCoord.xy - dir * - 0.5 * u"), out)
        XCTAssertTrue(out.contains("dir * 2.0 + v_TexCoord.xy"), out)
        XCTAssertTrue(out.contains("dir + (v_TexCoord * 2.0).xy"), out)
        XCTAssertTrue(out.contains("v_TexCoord + v_TexCoord * u)"), "same sizes: untouched: \(out)")
        XCTAssertTrue(out.contains("dir + v_TexCoord * g(1.0))"), "a factor of unknown size: untouched: \(out)")
    }

    /// HLSL lets a vertex shader modify its inputs; GLSL doesn't.
    func testWrittenAttributeBecomesAGlobalCopy() {
        let vertex = "#version 450\nin vec2 a_TexCoord;\nout vec2 v_TexCoord;\nvoid main() {\n a_TexCoord *= 2.0;\n v_TexCoord = a_TexCoord;\n}\n"
        let fragment = "#version 450\nin vec2 v_TexCoord;\nout vec4 out_FragColor;\nvoid main() { out_FragColor = vec4(v_TexCoord, 0.0, 1.0); }\n"
        let pair = ShaderPairRewriter.rewrite(vertex: vertex, fragment: fragment)
        XCTAssertTrue(pair.vertex.contains("layout(location = 1) in vec2 a_TexCoord_weIn;\nvec2 a_TexCoord;"), pair.vertex)
        XCTAssertTrue(pair.vertex.contains("a_TexCoord = a_TexCoord_weIn;"), pair.vertex)
        XCTAssertEqual(pair.attributes["a_TexCoord"], 1)
    }

    /// A header goes after a top-level `struct`, never inside its braces.
    func testIncludesAreNotInsertedInsideAStruct() {
        let text = "uniform float u;\nstruct Grid {\n vec2 id;\n};\nvoid main() {}\n"
        let offset = ShaderSourceLoader.includeInsertionOffset(in: text)
        XCTAssertEqual(offset, (text as NSString).range(of: "void main").location)
    }

    /// Locals and functions named with C++ keywords are renamed; a uniform keeps its name, since
    /// values bind to it by name.
    func testCppKeywordNamesCompileAndUniformsKeepTheirNames() throws {
        let source = "uniform float new;\nfloat operator(float this) { return this; }\nvoid main() { vec2 or = vec2(0.0); }"
        let prelude = ShaderPrelude.text(for: .fragment, combos: [:], source: source)
        for name in ["or", "this", "operator"] { XCTAssertTrue(prelude.contains("#define \(name) we_\(name)"), name) }
        XCTAssertFalse(prelude.contains("#define new "))
        XCTAssertFalse(prelude.contains("#define not "), "`not` is a GLSL built-in")
        _ = try translateDialectFixture("reserved")
    }

    func testUnmatchedEndifIsDropped() {
        let text = ShaderSourceLoader.dropUnmatchedEndifs(in: "#if A\n#endif\n#endif\n#ifdef B\n#endif")
        XCTAssertEqual(text, "#if A\n#endif\n// (unmatched) #endif\n#ifdef B\n#endif")
    }

    /// `vec4` out of the vertex stage, `vec2` into the fragment stage: Metal needs matching types.
    func testVaryingDeclaredWithDifferentSizesLinks() throws {
        let variant = try translateDialectFixture("varyings")
        XCTAssertTrue(variant.fragmentMSL.contains("float4 v_TexCoord_weVarying"), variant.fragmentMSL)
    }

    /// A header's own include is emitted before the header that uses it.
    func testNestedIncludesComeBeforeTheirIncluder() throws {
        let source = try ShaderSourceLoader(roots: [Fixtures.url("ShaderAssets")])
            .load("effects/dialect/shaders/effects/includes", stage: .fragment)
        let inner = try XCTUnwrap(source.text.range(of: "vec3 Inner("))
        let outer = try XCTUnwrap(source.text.range(of: "vec3 Outer("))
        XCTAssertLessThan(inner.lowerBound, outer.lowerBound)
        _ = try translateDialectFixture("includes")
    }

    func testShakeTexturesLandInTheirOwnSlots() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.weAssets.path), "WE install not present")
        let loader = ShaderSourceLoader(roots: [Self.weAssets])
        let path = "effects/shake/shaders/effects/shake"
        let vertex = try loader.load(path, stage: .vertex)
        let fragment = try loader.load(path, stage: .fragment)
        let combos = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment,
                                                           overrides: [["AUDIOPROCESSING": 1, "NOISE": 1]],
                                                           boundTextureSlots: [0, 1, 3])
        XCTAssertEqual(combos["MASK"], 1, "g_Texture3 is annotated combo MASK")
        let variant = try translator.variant(vertex: vertex, fragment: fragment, combos: combos)
        XCTAssertTrue(variant.fragmentMSL.contains("g_Texture1 [[texture(1)]]"), "slot must equal N")
        XCTAssertTrue(variant.fragmentMSL.contains("g_Texture3 [[texture(3)]]"))
        let spectrum = try XCTUnwrap(variant.uniforms?.members["g_AudioSpectrum16Left"])
        XCTAssertEqual(spectrum.count, 16)
        XCTAssertEqual(spectrum.arrayStride, 16, "std140 float arrays have a 16-byte stride")
        XCTAssertNoThrow(try Self.makePipeline(variant, device: try XCTUnwrap(MTLCreateSystemDefaultDevice())))
    }

    /// Every built-in effect pair, default combos: translate, compile MSL, build a pipeline.
    func testEveryBuiltinEffectPairBuildsAPipeline() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.weAssets.path), "WE install not present")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let loader = ShaderSourceLoader(roots: [Self.weAssets])
        let effects = Self.weAssets.appending(path: "effects")
        var pairs: [String] = []
        for effect in try FileManager.default.contentsOfDirectory(atPath: effects.path).sorted() {
            let shaders = effects.appending(path: "\(effect)/shaders/effects")
            for file in (try? FileManager.default.contentsOfDirectory(atPath: shaders.path)) ?? [] where file.hasSuffix(".frag") {
                pairs.append("effects/\(effect)/shaders/effects/\(file.dropLast(5))")
            }
        }
        XCTAssertGreaterThanOrEqual(pairs.count, 68)
        var failures: [String] = []
        for path in pairs {
            do {
                let vertex = try loader.load(path, stage: .vertex)
                let fragment = try loader.load(path, stage: .fragment)
                let combos = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment, overrides: [], boundTextureSlots: [0])
                let variant = try translator.variant(vertex: vertex, fragment: fragment, combos: combos)
                _ = try Self.makePipeline(variant, device: device)
            } catch {
                failures.append("\(path): \(String(describing: error).prefix(300))")
            }
        }
        XCTAssertEqual(failures, [], "\(failures.count) of \(pairs.count) failed:\n" + failures.joined(separator: "\n"))
    }
}
