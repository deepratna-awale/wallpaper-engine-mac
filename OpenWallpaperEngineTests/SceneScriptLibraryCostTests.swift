import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// The scripts' cost per frame on every scene of a local library, drawn by the renderer
/// (docs/scenescript-plan.md §4.6, WP11): CPU time of the script thread for a whole script frame,
/// and the render thread's share (taking the scripts' state, handing them the frame). Skipped when
/// the library is absent (CI); `OWE_LIBRARY` overrides it. Set `TEST_RUNNER_OWE_SCRIPT_COST_REPORT`
/// on `xcodebuild` to get the table as a file.
///
/// Plan §4.6's target is under 0.5 ms per frame; the table is how it is checked (in an optimized
/// build signed with the app's entitlements, so JavaScriptCore JIT-compiles as in the app; an
/// unsigned host such as CI's runs the interpreter, `SceneScriptJIT`). The assertion only guards
/// against regressions an order of magnitude past it.
final class SceneScriptLibraryCostTests: XCTestCase {
    /// Plan §4.6: under half a millisecond of script time per frame.
    static let budgetMilliseconds = 0.5
    static let regressionGuard = 10 * budgetMilliseconds
    /// Ten seconds at 60 fps before measuring.
    static let warmUpFrames = 600

    func testEveryLibrarySceneRunsItsScriptsUnderBudget() throws {
        let library = LibrarySweepTests.libraryRoot
        try XCTSkipUnless(FileManager.default.fileExists(atPath: library.path), "wallpaper library not present")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let storage = FileManager.default.temporaryDirectory.appending(path: "owe-script-cost-\(UUID().uuidString)")
        defer {
            do {
                if FileManager.default.fileExists(atPath: storage.path) { try FileManager.default.removeItem(at: storage) }
            } catch {
                XCTFail("Removing \(storage.path) failed: \(error)")
            }
        }
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                                           media: SceneScriptReplayMediaSource(), spectrum: { .silent })
        var report = "wallpaper\tframes\tscript p50 ms\tscript p99 ms\tscript mean ms\trender-thread p50 ms\n"
        var over: [String] = []
        for id in try FileManager.default.contentsOfDirectory(atPath: library.path).sorted() {
            let directory = library.appending(path: id, directoryHint: .isDirectory)
            guard let data = FileManager.default.contents(atPath: directory.appending(path: "project.json").path),
                  let project = try? JSONDecoder().decode(WEProject.self, from: data), // optional: not every folder is a wallpaper
                  project.type.lowercased() == "scene" else { continue }
            let model = SceneWallpaperViewModel(wallpaper: WEWallpaper(using: project, where: directory))
            guard let content = model.metalContent(), content.scripts != nil else { continue }
            let view = MTKView(frame: CGRect(x: 0, y: 0, width: 480, height: 270), device: device)
            view.colorPixelFormat = .bgra8Unorm
            view.framebufferOnly = false
            view.autoResizeDrawable = false
            view.drawableSize = CGSize(width: 480, height: 270)
            let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: services, screenID: "cost"))
            view.isPaused = true
            renderer.setContent(content)
            let deadline = Date().addingTimeInterval(60)
            while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            guard let wallpaper = renderer.scripts.wallpaper else {
                renderer.releaseContent()
                continue
            }
            // Warm up, then measure the steady state: JavaScriptCore compiles a script's functions
            // tier by tier as they run (baseline on the script thread, then DFG and FTL), and
            // `update` runs once a frame, so the first seconds carry compile spikes.
            for _ in 0..<Self.warmUpFrames { step(renderer, view: view, wallpaper: wallpaper) }
            let measured = wallpaper.frameTiming.frames
            let bridgeStart = renderer.scripts.bridgeMilliseconds.count
            for _ in 0..<240 { step(renderer, view: view, wallpaper: wallpaper) }
            let timing = wallpaper.frameTiming
            let script = Array(timing.recentMilliseconds.suffix(timing.frames - measured))
            let bridge = Array(renderer.scripts.bridgeMilliseconds.dropFirst(bridgeStart))
            let p50 = Self.percentile(script, 0.5)
            let row = [id, String(script.count), Self.format(p50), Self.format(Self.percentile(script, 0.99)),
                       Self.format(script.reduce(0, +) / Double(max(script.count, 1))), Self.format(Self.percentile(bridge, 0.5))]
            report += row.joined(separator: "\t") + "\n"
            if p50 >= Self.regressionGuard { over.append("\(id): \(Self.format(p50)) ms") }
            renderer.releaseContent()
            Fixtures.removeStoredSettings(for: directory)
        }
        if let path = ProcessInfo.processInfo.environment["OWE_SCRIPT_COST_REPORT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(over.isEmpty, "script frames at or over \(Self.regressionGuard) ms (p50): \(over)\n\(report)")
    }

    /// One drawn frame, then the script frame it started.
    private func step(_ renderer: SceneMetalRenderer, view: MTKView, wallpaper: SceneScriptWallpaper) {
        RunLoop.main.run(until: Date())
        renderer.draw(in: view)
        renderer.lastCommandBuffer?.waitUntilCompleted()
        wallpaper.waitUntilIdle()
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }

    private static func format(_ value: Double) -> String { String(format: "%.3f", value) }
}
