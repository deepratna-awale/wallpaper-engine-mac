import XCTest
import MetalKit
import simd
@testable import OpenWallpaperEngine

/// Whole frames of chosen library wallpapers, drawn by the renderer as the app draws them (layers,
/// effects, particles through their materials, scripts, the post-process), to find what makes a
/// wallpaper slow. Only runs when asked: `OWE_SCENE_BENCH` (`TEST_RUNNER_OWE_SCENE_BENCH` through
/// xcodebuild) lists workshop ids, or is `playlist:<name>` for a playlist of the app's; skipped
/// otherwise and without the library (`OWE_LIBRARY`).
///
/// Each wallpaper is drawn at every size of `OWE_SCENE_BENCH_SIZES` (default 1920x1080 and
/// 3840x2160, a 4K display at 2×: the scene target follows the drawable,
/// `SceneRenderResolution`), as a whole, without its particle systems, with them alone, and under
/// each particle budget that thins it (`ParticleBudget`). A row gives the GPU time (the least of the
/// measured frames, and the median), the render thread's CPU time for `draw(in:)` (median; it
/// includes the wait for the script frame) and the script thread's frame (median). Written to
/// `OWE_BENCH_OUT` when set.
final class SceneFrameBenchmarkTests: XCTestCase {
    private struct Measure {
        var gpuMin = 0.0
        var gpuMedian = 0.0
        var cpuMedian = 0.0
        var scriptMedian = 0.0
        var particleCapacity = 0
    }

    private enum Variant: CustomStringConvertible {
        case full, withoutParticles, particlesOnly, withoutEffects, budget(GSParticleBudget)

        var description: String {
            switch self {
            case .full: return "full"
            case .withoutParticles: return "no particles"
            case .particlesOnly: return "particles only"
            case .withoutEffects: return "no effects"
            case .budget(let budget): return "budget \(budget.rawValue)"
            }
        }
    }

    func testSceneFrameCost() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let request = environment["OWE_SCENE_BENCH"], !request.isEmpty else {
            throw XCTSkip("set OWE_SCENE_BENCH to run the scene benchmark")
        }
        let library = LibrarySweepTests.libraryRoot
        try XCTSkipUnless(FileManager.default.fileExists(atPath: library.path), "wallpaper library not present")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let storage = FileManager.default.temporaryDirectory.appending(path: "owe-scene-bench-\(UUID().uuidString)")
        defer {
            do {
                if FileManager.default.fileExists(atPath: storage.path) { try FileManager.default.removeItem(at: storage) }
            } catch {
                XCTFail("Removing \(storage.path) failed: \(error)")
            }
        }
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                                           media: SceneScriptReplayMediaSource(), spectrum: { .silent })
        let sizes = (environment["OWE_SCENE_BENCH_SIZES"] ?? "1920x1080,3840x2160").split(separator: ",").compactMap { entry -> SIMD2<Int>? in
            let parts = entry.split(separator: "x").compactMap { Int($0) }
            return parts.count == 2 ? SIMD2(parts[0], parts[1]) : nil
        }
        var lines = ["Scene frame cost (ms): GPU min / median, render-thread CPU median, script median; particle capacity"]
        for directory in try Self.wallpapers(request, library: library) {
            guard let data = FileManager.default.contents(atPath: directory.appending(path: "project.json").path),
                  let project = try? JSONDecoder().decode(WEProject.self, from: data), // optional: not every folder is a wallpaper
                  project.type.lowercased() == "scene" else {
                lines.append("\(directory.lastPathComponent): not a scene; skipped")
                continue
            }
            let restore = Self.keepStoredSettings(directory: directory, projectData: data)
            defer { restore() }
            let model = SceneWallpaperViewModel(wallpaper: WEWallpaper(using: project, where: directory))
            var unlimited = SceneRenderSettings()
            unlimited.particleBudget = .unlimited
            model.setRenderSettings(unlimited)
            guard let content = model.metalContent() else {
                lines.append("\(directory.lastPathComponent): no content")
                continue
            }
            let authored = content.particleSystems.reduce(0) { $0 + ParticleBudget.capacity(of: $1) }
            let refracting = content.particleSystems.filter { $0.material?.stages.contains(where: \.readsSceneSnapshot) == true }
            let effects = content.layers.reduce(0) { $0 + $1.weEffects.count }
            lines.append(String(format: "%@ “%@”: scene %.0fx%.0f, %d layers, %d effects, %d particle systems (%d refracting), %d particles authored",
                                directory.lastPathComponent, project.title, content.size.x, content.size.y, content.layers.count,
                                effects, content.particleSystems.count, refracting.count, authored))
            var variants: [Variant] = [.full]
            if effects > 0 { variants.append(.withoutEffects) }
            if !content.particleSystems.isEmpty {
                variants += [.withoutParticles, .particlesOnly]
                for budget in [GSParticleBudget.high, .medium, .low] where ParticleBudget.scale(authored: authored, budget: budget.limit) < 1 {
                    variants.append(.budget(budget))
                }
            }
            for size in sizes {
                for variant in variants {
                    var drawn = content
                    switch variant {
                    case .full: break
                    case .withoutEffects:
                        let plain = content.layers.map { layer -> SceneMetalLayer in
                            var layer = layer
                            layer.weEffects = []
                            return layer
                        }
                        drawn = Self.content(content, layers: plain, particleSystems: content.particleSystems)
                    case .withoutParticles: drawn = Self.content(content, layers: content.layers, particleSystems: [])
                    case .particlesOnly:
                        drawn = Self.content(content, layers: [], particleSystems: content.particleSystems)
                        drawn.scripts = nil
                    case .budget(let budget):
                        var settings = SceneRenderSettings()
                        settings.particleBudget = budget
                        model.setRenderSettings(settings)
                        drawn = try XCTUnwrap(model.metalContent())
                        model.setRenderSettings(unlimited)
                    }
                    let measure = try frameCost(drawn, size: size, device: device, services: services)
                    lines.append(String(format: "  %4dx%-4d %-16@ gpu %7.3f / %7.3f  cpu %6.3f  script %6.3f  particles %d",
                                        size.x, size.y, variant.description as NSString, measure.gpuMin, measure.gpuMedian,
                                        measure.cpuMedian, measure.scriptMedian, measure.particleCapacity))
                    print(lines.last!)
                }
            }
            // What each layer's effects shade a frame: every render pass's target, in megapixels. Frame
            // timings of one layer left out are too noisy with other GPU work on the machine; this isn't.
            var fills: [(pixels: Double, line: String)] = []
            for layer in content.layers where !layer.weEffects.isEmpty {
                let pixels = Self.effectPixels(layer)
                let files = layer.weEffects.map { ($0.file as NSString).deletingLastPathComponent.split(separator: "/").last.map(String.init) ?? $0.file }
                fills.append((pixels, String(format: "    layer %@ “%@” %@: %@, %d passes, %.1f MPix a frame", layer.id, layer.name,
                                             Self.inputSizeDescription(layer), files.joined(separator: ","),
                                             layer.weEffects.reduce(0) { $0 + $1.passes.count }, pixels / 1e6)))
            }
            let total = fills.reduce(0) { $0 + $1.pixels }
            lines.append(String(format: "  effects shade %.1f MPix a frame (a 3840x2160 target is 8.3)", total / 1e6))
            lines += fills.sorted { $0.pixels > $1.pixels }.prefix(6).map(\.line)
        }
        let report = lines.joined(separator: "\n")
        print(report)
        if let path = environment["OWE_BENCH_OUT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// The pixels `layer`'s effect passes render a frame: each render pass's target, the layer's
    /// input size or its FBO's (`EffectGraphRenderer.fboSize`).
    private static func effectPixels(_ layer: SceneMetalLayer) -> Double {
        let input = inputSize(layer)
        return layer.weEffects.reduce(0) { total, effect in
            let fbos = Dictionary(effect.fbos.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            return total + effect.passes.reduce(0) { sum, pass in
                guard case .render = pass.command else { return sum }
                let size = pass.target.flatMap { fbos[$0] }.map { EffectGraphRenderer.fboSize($0, width: input.x, height: input.y) } ?? input
                return sum + Double(size.x) * Double(size.y)
            }
        }
    }

    private static func inputSize(_ layer: SceneMetalLayer) -> SIMD2<Int> {
        let pixels = layer.source.pixelSize
        let size = pixels.x > 0 && pixels.y > 0 ? pixels : layer.size
        return SIMD2(Int(size.x.rounded()), Int(size.y.rounded()))
    }

    private static func inputSizeDescription(_ layer: SceneMetalLayer) -> String {
        let size = inputSize(layer)
        return "\(size.x)x\(size.y)"
    }

    /// `content` with other layers and particle systems.
    private static func content(_ content: SceneMetalContent, layers: [SceneMetalLayer],
                                particleSystems: [SceneMetalParticleSystem]) -> SceneMetalContent {
        var copy = SceneMetalContent(size: content.size, layers: layers, particleSystems: particleSystems, bloom: content.bloom)
        copy.transforms = content.transforms
        copy.motions = content.motions
        copy.camera = content.camera
        copy.wallpaperKey = content.wallpaperKey
        copy.visibility = content.visibility
        copy.objectIDs = content.objectIDs
        copy.scripts = content.scripts
        copy.timelines = content.timelines
        copy.sounds = content.sounds
        copy.lighting = content.lighting
        copy.engineCombos = content.engineCombos
        return copy
    }

    /// The wallpapers `request` names: workshop ids, or `playlist:<name>` for a playlist's scenes.
    private static func wallpapers(_ request: String, library: URL) throws -> [URL] {
        guard request.hasPrefix("playlist:") else {
            return request.split(separator: ",").map { library.appending(path: String($0), directoryHint: .isDirectory) }
        }
        let name = String(request.dropFirst("playlist:".count))
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: "WallpaperPlaylists"), "no playlists stored")
        struct Playlist: Decodable {
            struct Item: Decodable {
                struct Wallpaper: Decodable { let wallpaperDirectory: URL }
                let wallpaper: Wallpaper
            }
            let name: String
            let items: [Item]
        }
        let playlist = try XCTUnwrap(try JSONDecoder().decode([Playlist].self, from: data).first { $0.name == name },
                                     "no playlist \(name)")
        return playlist.items.map(\.wallpaper.wallpaperDirectory)
    }

    /// Loading a wallpaper stores its settings; this puts back what was stored before (nothing, for a
    /// wallpaper never opened), so the benchmark leaves the user's settings as they were.
    private static func keepStoredSettings(directory: URL, projectData: Data) -> () -> Void {
        let identity = WallpaperSettingsIdentity(directory: directory, projectData: projectData)
        var keys: [String] = ["SceneAdditionalControlsVersion." + directory.path]
        for family in WallpaperSettingsIdentity.Family.allCases {
            keys.append(identity.key(family))
            keys.append(family.rawValue + directory.path)
        }
        let before = keys.map { UserDefaults.standard.object(forKey: $0) }
        return {
            for (key, value) in zip(keys, before) {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }

    private static func median(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.sorted()[values.count / 2]
    }

    /// Frames of `content` at `size`: two and a half seconds at 60 fps to load, compile and fill,
    /// then 60 frames back to back.
    private func frameCost(_ content: SceneMetalContent, size: SIMD2<Int>, device: MTLDevice,
                           services: SceneScriptServices) throws -> Measure {
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: size.x / 2, height: size.y / 2), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: size.x, height: size.y)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: services, screenID: "bench"))
        view.isPaused = true
        renderer.setPlacement(.fill)
        renderer.setContent(content)
        defer { renderer.releaseContent() }
        let deadline = Date().addingTimeInterval(60)
        while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        if let materials = ParticleMaterialRenderer(device: device) {
            for plan in content.particleSystems.compactMap(\.material) {
                _ = materials.waitUntilCompiled(plan, pixelFormat: .bgra8Unorm)
            }
        }
        var gpu: [Double] = [], cpu: [Double] = [], script: [Double] = []
        for frame in 0..<210 {
            if frame < 150 { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60)) } else { RunLoop.main.run(until: Date()) }
            let scriptFrames = renderer.scripts.wallpaper?.frameTiming.frames ?? 0
            let start = CACurrentMediaTime()
            renderer.draw(in: view)
            let elapsed = CACurrentMediaTime() - start
            guard let commandBuffer = renderer.lastCommandBuffer else { continue }
            commandBuffer.waitUntilCompleted()
            renderer.scripts.wallpaper?.waitUntilIdle()
            guard frame >= 150 else { continue }
            gpu.append((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000)
            cpu.append(elapsed * 1000)
            if let timing = renderer.scripts.wallpaper?.frameTiming, timing.frames > scriptFrames {
                script.append(timing.recentMilliseconds.last ?? 0)
            }
        }
        let capacity = content.particleSystems.reduce(0) { total, system in
            total + Int((Float(ParticleBudget.capacity(of: system)) * system.budgetScale).rounded())
        }
        return Measure(gpuMin: gpu.min() ?? 0, gpuMedian: Self.median(gpu), cpuMedian: Self.median(cpu),
                       scriptMedian: Self.median(script), particleCapacity: capacity)
    }
}
