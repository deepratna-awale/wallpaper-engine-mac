import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// Timelines end to end (docs/timeline-plan.md T3): `Scenes/timeline` loaded through the real
/// loader and drawn headlessly at a stepped clock, the library's shapes checked in the pixels. An
/// alpha fade follows the reference model; relative origin, scale and angles move their layer; a
/// start-paused single holds its first keyframe until a script plays it, and its linked child
/// follows; scripts on animated fields see and beat the animated value for their frame (P2); an
/// effect constant animates; a sprite sheet steps on its shared clock unless a script holds it.
final class TimelineRenderTests: XCTestCase {
    private var storage: URL!
    private static let step = 1.0 / 60

    override func setUpWithError() throws {
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-render-timeline-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let storage, FileManager.default.fileExists(atPath: storage.path) {
            try FileManager.default.removeItem(at: storage)
        }
    }

    /// Alpha on WE's default (ease) handles with `wraploop`, against the float32 model stepped by
    /// the same deltas.
    func testAnAlphaLoopFollowsTheModel() throws {
        let scene = try Scene(services: services())
        defer { scene.close() }
        var model = try Self.timeline(of: 1, key: "alpha")
        for (frames, label) in [(0, "t = 0"), (30, "t = ½ s"), (30, "t = 1 s"), (45, "t = 1¾ s, on the way back")] {
            let pixels = try scene.draw(frames: frames)
            for _ in 0..<frames { model.clock.advance(by: Float(Self.step)) }
            let expected = model.value()[0]
            XCTAssertEqual(Float(pixels.rgb(8, 32).x) / 255, expected, accuracy: 3 / 255, label)
        }
    }

    /// A `relative` origin is baked on the authored value; scale and `angles.z` animate (roadmap E7).
    func testOriginScaleAndAnglesAnimate() throws {
        let scene = try Scene(services: services())
        defer { scene.close() }
        var pixels = try scene.draw(frames: 0)
        XCTAssertEqual(pixels.color(24, 40), .red, "Slide starts at its authored origin")
        XCTAssertEqual(pixels.color(107, 16), .black, "Grow is 4 wide")
        XCTAssertEqual(pixels.color(106, 46), .blue, "Turn lies flat")
        XCTAssertEqual(pixels.color(100, 52), .black)

        pixels = try scene.draw(frames: 70)
        XCTAssertEqual(pixels.color(64, 40), .red, "Slide moved by its 40-unit offset")
        XCTAssertEqual(pixels.color(24, 40), .black)
        XCTAssertEqual(pixels.color(107, 16), .green, "Grow was scaled 4×")
        XCTAssertEqual(pixels.color(100, 52), .blue, "Turn stands up")
        XCTAssertEqual(pixels.color(106, 46), .black)
    }

    /// A `startpaused` single holds its first keyframe, not the authored value; a script's
    /// `play()` runs it once, and the `alpha` linked to it runs on its clock (§2.5).
    func testAStartPausedParentPlayedByAScriptRunsItsLinkedChild() throws {
        let scene = try Scene(services: services())
        defer { scene.close() }
        XCTAssertEqual(try scene.draw(frames: 6).color(40, 8), .black, "alpha holds c0[0] = 0, not its value 1")
        XCTAssertEqual(try scene.draw(frames: 80).color(40, 8), .yellow, "played on frame 10, done a second later")
        let set = try XCTUnwrap(scene.renderer.animations)
        let origin = SceneAnimationSite(owner: .object(5), key: "origin")
        XCTAssertEqual(set.state(of: origin)?.flags.contains(.finished), true)
        XCTAssertEqual(set.clockOwner(of: SceneAnimationSite(owner: .object(5), key: "alpha")), origin)
    }

    /// P2: `update(value)` gets this frame's animated value and its return is drawn; an
    /// accumulator adds to the animated value each frame instead of running away.
    func testScriptsOnAnimatedFieldsSeeAndBeatTheAnimation() throws {
        let scene = try Scene(services: services())
        defer { scene.close() }
        let pixels = try scene.draw(frames: 90)
        XCTAssertEqual(Float(pixels.rgb(60, 56).x) / 255, 0.3, accuracy: 3 / 255, "update(v) { return v } draws the timeline")
        XCTAssertEqual(Float(pixels.rgb(76, 56).x) / 255, 0.5, accuracy: 3 / 255, "0.3 animated + 0.2, every frame")
    }

    /// Without scripts the animated values are drawn all the same (the set is the renderer's).
    func testTimelinesRunWithoutScripts() throws {
        let scene = try Scene(services: nil)
        defer { scene.close() }
        let pixels = try scene.draw(frames: 70)
        XCTAssertEqual(pixels.color(64, 40), .red)
        XCTAssertEqual(Float(pixels.rgb(60, 56).x) / 255, 0.3, accuracy: 3 / 255)
        XCTAssertEqual(pixels.color(40, 8), .black, "nobody plays the paused one")
    }

    /// An effect constant's timeline (`passes[0].constantshadervalues.color`) reaches the shader.
    func testAnEffectConstantAnimates() throws {
        try XCTSkipUnless(Fixtures.hasWEShaderSources, "WE's effect shaders are not available")
        let scene = try Scene(services: nil)
        defer { scene.close() }
        let tinted = try XCTUnwrap(scene.renderer.effectPlans(ofLayer: "8").first)
        let color = try XCTUnwrap(tinted.passes.first?.constants.dynamic.first { $0.uniform.lowercased().contains("color") })
        guard case .animation(let site?, _) = color.source else { return XCTFail("\(color.source)") }
        XCTAssertEqual(site, SceneAnimationSite(owner: .material(object: 8, effect: 0, pass: 0), key: "color"))
        // Pipelines compile off the render thread; the layer draws plain white until then.
        let pixels = try scene.draw(frames: 70) { $0.color(16, 8) == .white }
        XCTAssertEqual(pixels.color(16, 8), .blue, "red → blue over a second, held at its end")
    }

    /// Every layer drawing a sprite sheet shares its clock, which steps one frame per engine frame
    /// at most; a layer whose script paused its `ITextureAnimation` holds its frame (§2.7, §3.2).
    func testSpriteFramesFollowTheSharedClockUnlessAScriptHoldsThem() throws {
        let scene = try Scene(services: services())
        defer { scene.close() }
        var pixels = try scene.draw(frames: 15)
        XCTAssertEqual(pixels.color(120, 8), .red, "frame 0 for its 0.5 s")
        pixels = try scene.draw(frames: 30)
        XCTAssertEqual(pixels.color(120, 8), .green, "frame 1")
        XCTAssertEqual(pixels.color(120, 24), .red, "paused in init on frame 0")
        pixels = try scene.draw(frames: 30)
        XCTAssertEqual(pixels.color(120, 8), .red, "wrapped to frame 0")
        let held = try XCTUnwrap(scene.renderer.animations?.textures.state(object: 10))
        XCTAssertTrue(held.control.overridden)
        XCTAssertFalse(held.control.playing)
        XCTAssertEqual(held.sharedFrame, 0)
    }

    // MARK: - Cost

    /// The per-frame cost of the timelines: the set's advance and the renderer's reads, for the
    /// library's largest shape (64 timelines, 3 channels, 600 frames), after the sample caches warm.
    func testThePerFrameCostIsSmall() throws {
        var objects: [String] = []
        for index in 0..<64 {
            let keys = (0..<3).map { channel in
                #""c\#(channel)": [{"frame": 0, "value": 0}, {"frame": 300, "value": \#(index)}, {"frame": 600, "value": 0}]"#
            }.joined(separator: ", ")
            objects.append(#"{"id": \#(index), "origin": {"value": "0 0 0", "animation": {\#(keys), "options": {"fps": 60, "length": 600, "mode": "loop"}}}}"#)
        }
        let document = try JSONDecoder().decode(SceneJSON.self, from: Data(#"{"objects": [\#(objects.joined(separator: ","))]}"#.utf8))
        let set = SceneAnimationSet(document: document, wallpaperID: "cost")
        XCTAssertEqual(set.sites.count, 64)
        for _ in 0..<1200 { set.advance(by: 1 / 60) }
        let frames = 600
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        for _ in 0..<frames { set.advance(by: 1 / 60) }
        let advanced = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        for _ in 0..<frames {
            for id in 0..<64 { _ = SceneObjectAnimation(set, object: id, keys: ["origin"]) }
        }
        let end = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let advance = Double(advanced - start) / 1000 / Double(frames), read = Double(end - advanced) / 1000 / Double(frames)
        let microseconds = advance + read
        print("Timeline cost: \(String(format: "%.1f", advance)) µs advance + \(String(format: "%.1f", read)) µs reads per frame, 64 timelines")
        XCTAssertLessThan(microseconds, 1000, "a millisecond is a frame's budget gone")
    }

    // MARK: - Support

    private static func timeline(of id: Int, key: String) throws -> SceneTimelineAnimation {
        let document = try JSONDecoder().decode(SceneJSON.self, from: Fixtures.data("Scenes/timeline/scene.json"))
        let holder = try XCTUnwrap(SceneAnimationHolders.holders(in: document).first {
            $0.site == SceneAnimationSite(owner: .object(id), key: key)
        })
        return try SceneTimelineAnimation(json: XCTUnwrap(holder.fields["animation"]), staticValue: holder.fields["value"])
    }

    private func services() -> SceneScriptServices {
        SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                            media: SceneScriptReplayMediaSource(), spectrum: { .silent })
    }

    /// The fixture on one offscreen view, its clock stepped by `step` per draw.
    private final class Scene {
        let renderer: SceneMetalRenderer
        let view: MTKView
        let directory: URL
        let size = SIMD2(128, 64)
        private var now: CFTimeInterval = 1000
        private var anchored = false

        init(services: SceneScriptServices?) throws {
            directory = Fixtures.url("Scenes/timeline")
            let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/timeline/project.json"))
            let model = SceneWallpaperViewModel(wallpaper: WEWallpaper(using: project, where: directory))
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            view = MTKView(frame: CGRect(x: 0, y: 0, width: size.x, height: size.y), device: device)
            view.colorPixelFormat = .bgra8Unorm
            view.framebufferOnly = false
            view.autoResizeDrawable = false
            view.drawableSize = CGSize(width: size.x, height: size.y)
            renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: services, screenID: "timeline"))
            view.isPaused = true
            renderer.setPlacement(.stretch)
            renderer.scripts.frameWait = 5
            renderer.wallTime = { [unowned self] in self.now }
            renderer.setContent(try XCTUnwrap(model.metalContent()))
            let deadline = Date().addingTimeInterval(30)
            while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertTrue(renderer.hasContent)
        }

        func close() {
            renderer.releaseContent()
            Fixtures.removeStoredSettings(for: directory)
        }

        /// Draws `frames` more frames (the first draw anchors the clock at 0 and is extra), then
        /// keeps drawing while `waiting` holds, and returns the last one's pixels.
        func draw(frames: Int, while waiting: (Pixels) -> Bool = { _ in false }) throws -> Pixels {
            var remaining = frames
            if !anchored {
                anchored = true
                remaining += 1
                now -= TimelineRenderTests.step
            }
            let deadline = Date().addingTimeInterval(30)
            var pixels = Pixels(bytes: [], size: size)
            repeat {
                now += TimelineRenderTests.step
                renderer.draw(in: view)
                renderer.lastCommandBuffer?.waitUntilCompleted()
                renderer.scripts.wallpaper?.waitUntilIdle()
                remaining -= 1
                pixels = read()
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            } while (remaining > 0 || waiting(pixels)) && Date() < deadline
            return pixels
        }

        private func read() -> Pixels {
            var bytes = [UInt8](repeating: 0, count: size.x * size.y * 4)
            view.currentDrawable?.texture.getBytes(&bytes, bytesPerRow: size.x * 4,
                                                   from: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0)
            return Pixels(bytes: bytes, size: size)
        }
    }

    enum Color: Equatable {
        case black, white, red, green, blue, yellow, other
    }

    struct Pixels {
        let bytes: [UInt8]
        let size: SIMD2<Int>

        /// (r, g, b) at a scene point (the scene is stretched over the view, y up).
        func rgb(_ x: Int, _ y: Int) -> SIMD3<UInt8> {
            let index = ((size.y - 1 - y) * size.x + x) * 4
            return SIMD3(bytes[index + 2], bytes[index + 1], bytes[index])
        }

        func color(_ x: Int, _ y: Int) -> Color {
            let c = rgb(x, y)
            func on(_ value: UInt8) -> Bool { value > 180 }
            func off(_ value: UInt8) -> Bool { value < 60 }
            switch (on(c.x), on(c.y), on(c.z)) {
            case (false, false, false) where off(c.x) && off(c.y) && off(c.z): return .black
            case (true, false, false) where off(c.y) && off(c.z): return .red
            case (false, true, false) where off(c.x) && off(c.z): return .green
            case (false, false, true) where off(c.x) && off(c.y): return .blue
            case (true, true, false) where off(c.z): return .yellow
            case (true, true, true): return .white
            default: return .other
            }
        }
    }
}
