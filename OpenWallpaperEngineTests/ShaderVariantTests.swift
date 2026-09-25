import XCTest
import Metal
@testable import OpenWallpaperEngine

final class ShaderVariantTests: XCTestCase {
    static let weAssets = URL(fileURLWithPath:
        "/Volumes/980Pro/Crossover/bottles/Steam Bottle/drive_c/Program Files (x86)/Steam/steamapps/common/wallpaper_engine/assets")

    private var translator: ShaderVariantTranslator!
    private var cache: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(SceneShaderTranslator.toolchain == nil, "glslang/spirv-cross not installed")
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-variants-\(UUID().uuidString)")
        translator = ShaderVariantTranslator(compiler: try ProcessShaderCompiler(), cacheDirectory: cache)
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
