import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// A media source the test drives.
private final class FakeMediaSessionSource: MediaSessionSource {
    private var update: ((MediaSessionState) -> Void)?
    private(set) var stopped = false

    func start(update: @escaping (MediaSessionState) -> Void) { self.update = update }
    func stop() { stopped = true }
    func send(_ state: MediaSessionState) { update?(state) }
}

/// `TestSceneScriptCompiler` with every callback WE calls exported.
private struct MediaTestCompiler: SceneScriptModuleCompiling {
    private static let exportNames = ["init", "update", "destroy", "mediaStatusChanged", "mediaPlaybackChanged",
                                      "mediaPropertiesChanged", "mediaThumbnailChanged", "mediaTimelineChanged"]

    func compile(_ source: String) throws -> SceneScriptCompiledModule {
        let getters = Self.exportNames
            .map { "get \($0)() { return typeof \($0) === 'undefined' ? undefined : \($0); }" }
            .joined(separator: ", ")
        let header = "(function (__rt, __scope) { 'use strict'; var thisLayer = __scope.thisLayer, thisObject = __scope.thisObject; "
        return SceneScriptCompiledModule(factorySource: header + source + "\nreturn { \(getters) }; })")
    }
}

/// The five media callbacks (docs/scenescript-plan.md WP6): WE's event objects, WE's order, the
/// current state right after `init`, and no event twice.
final class SceneScriptMediaTests: XCTestCase {
    /// Logs every media callback into `shared.log[<name>]`.
    private static func loggingScript(_ name: String) -> String {
        """
        shared.log = shared.log || {};
        shared.log['\(name)'] = [];
        function log(entry) { shared.log['\(name)'].push(entry); }
        function init(value) { log('init'); return value; }
        function mediaStatusChanged(event) { log('status ' + event.enabled); }
        function mediaPlaybackChanged(event) { log('playback ' + event.state); }
        function mediaPropertiesChanged(event) {
            log('properties ' + [event.title, event.artist, event.subTitle, event.albumTitle, event.albumArtist,
                                 event.genres, event.contentType].join('|'));
        }
        function mediaThumbnailChanged(event) {
            log('thumbnail ' + event.hasThumbnail + ' ' + (event.primaryColor instanceof Vec3) + ' ' +
                [event.primaryColor, event.secondaryColor, event.tertiaryColor, event.textColor,
                 event.highContrastColor].map(function (c) { return c.toString(); }).join(','));
        }
        function mediaTimelineChanged(event) { log('timeline ' + event.position + '/' + event.duration); }
        """
    }

    private let source = FakeMediaSessionSource()

    private func makeRuntime() throws -> SceneScriptRuntime {
        try SceneScriptRuntime(host: TestSceneScriptHost(), compiler: MediaTestCompiler(),
                               extensions: [SceneScriptMediaExtension(source: source)])
    }

    private func log(_ name: String, in runtime: SceneScriptRuntime) -> [String] {
        runtime.context.evaluateScript("shared.log['\(name)']")?.toArray() as? [String] ?? []
    }

    private var playing: MediaSessionState {
        var state = MediaSessionState()
        state.enabled = true
        state.playback = .playing
        state.properties = .init(title: "Song", artist: "Artist", albumTitle: "Album", genres: "Pop,Rock",
                                 contentType: "audio")
        state.thumbnail = .init(artwork: 1, colors: ArtworkPalette.Colors(
            primary: SIMD3(1, 0, 0), secondary: SIMD3(0, 0, 1), tertiary: SIMD3(0, 1, 0),
            text: SIMD3(0, 1, 0), highContrast: .zero))
        state.timeline = .init(position: 10, duration: 200)
        return state
    }

    func testANewScriptGetsTheCurrentStateRightAfterInitAndNothingTwice() throws {
        let runtime = try makeRuntime()
        source.send(playing)
        runtime.add(SceneScriptInstance(id: "a", source: Self.loggingScript("a")))
        runtime.load()
        let expected = [
            "init", "status true", "playback 1", "properties Song|Artist||Album||Pop,Rock|audio",
            "thumbnail true true 1 0 0,0 0 1,0 1 0,0 1 0,0 0 0", "timeline 10/200",
        ]
        XCTAssertEqual(log("a", in: runtime), expected)
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(log("a", in: runtime), expected, "the queued events of the same state are not repeated")
    }

    func testChangesArriveAsEventsInWEOrder() throws {
        let runtime = try makeRuntime()
        runtime.add(SceneScriptInstance(id: "a", source: Self.loggingScript("a")))
        runtime.load()
        XCTAssertEqual(log("a", in: runtime), ["init"], "an empty, disabled state sends nothing at init")

        source.send(playing)
        XCTAssertEqual(log("a", in: runtime), ["init"], "events wait for the next frame")
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(Array(log("a", in: runtime).dropFirst()), [
            "status true", "playback 1", "properties Song|Artist||Album||Pop,Rock|audio",
            "thumbnail true true 1 0 0,0 0 1,0 1 0,0 1 0,0 0 0", "timeline 10/200",
        ])

        var paused = playing
        paused.playback = .paused
        source.send(paused)
        var next = paused
        next.timeline.position = 11
        source.send(next)
        source.send(next)
        var noArtwork = next
        noArtwork.thumbnail = .init()
        source.send(noArtwork)
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(Array(log("a", in: runtime).dropFirst(6)), [
            "playback 2", "timeline 11/200", "thumbnail false true 0 0 0,0 0 0,0 0 0,0 0 0,0 0 0",
        ])
    }

    func testAScriptAddedLaterStartsFromTheCurrentState() throws {
        let runtime = try makeRuntime()
        runtime.add(SceneScriptInstance(id: "a", source: Self.loggingScript("a")))
        runtime.load()
        source.send(playing)
        var paused = playing
        paused.playback = .paused
        source.send(paused)
        runtime.add(SceneScriptInstance(id: "b", source: Self.loggingScript("b")))
        runtime.load()
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(log("b", in: runtime), [
            "init", "status true", "playback 2", "properties Song|Artist||Album||Pop,Rock|audio",
            "thumbnail true true 1 0 0,0 0 1,0 1 0,0 1 0,0 0 0", "timeline 10/200",
        ])
        XCTAssertEqual(log("a", in: runtime).filter { $0.hasPrefix("playback") }, ["playback 1", "playback 2"])
    }

    func testAThrowingMediaCallbackIsDisabledAlone() throws {
        let runtime = try makeRuntime()
        runtime.add(SceneScriptInstance(id: "a", source: """
            shared.calls = [];
            function mediaPlaybackChanged(event) { shared.calls.push('playback'); throw new Error('boom'); }
            function mediaTimelineChanged(event) { shared.calls.push('timeline'); }
            """))
        runtime.load()
        source.send(playing)
        runtime.frame(deltaTime: 1.0 / 60)
        var later = playing
        later.playback = .paused
        later.timeline.position = 12
        source.send(later)
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(runtime.context.evaluateScript("shared.calls.join(',')")?.toString(), "playback,timeline,timeline")
    }

    func testTheSourceStopsWithTheRuntime() throws {
        var runtime: SceneScriptRuntime? = try makeRuntime()
        XCTAssertFalse(source.stopped)
        runtime?.tearDown()
        runtime = nil
        XCTAssertTrue(source.stopped)
    }
}
