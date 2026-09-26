import Foundation
import XCTest
@testable import OpenWallpaperEngine

/// WP9 of docs/scenescript-plan.md: every script of every corpus wallpaper, at its real attachment
/// site, on the SceneScript runtime for 600 frames of fake clock, audio, cursor, media and property
/// changes (`SceneScriptReplayHarness`). The corpus part is skipped when the corpus is absent (CI);
/// the synthetic fixtures in `Tests/Fixtures/SceneScript/replay` always run. A corpus wallpaper
/// that changed since the corpus was extracted (`SceneScriptCorpus.state`) is replayed without
/// the site count check; one that left the library is skipped. The attachment lists both.
///
/// A finding outside `expectedFailures` fails the test. Each expected entry is an `XCTExpectFailure`
/// naming its reason, and fails once the finding is gone, so the list only shrinks.
final class SceneScriptCorpusReplayTests: XCTestCase {
    struct ExpectedFailure {
        /// A corpus script hash, or a wallpaper id for wallpaper-wide findings (budget, strings).
        var key: String
        var check: SceneScriptReplayChecks.Check
        var reason: String
    }

    private static let roots = SceneScriptCorpus.roots

    /// Findings of the corpus replay that are known. Findings RF*n* are written up in
    /// docs/scenescript-replay-findings.md.
    static let expectedFailures: [ExpectedFailure] = [
        ExpectedFailure(key: "8bb9b9a54120", check: .exception,
                        reason: "3802509485's string literal broken across two lines: V8 rejects it too, so WE never runs it"),
        ExpectedFailure(key: "03f0db0a6dff", check: .exception,
                        reason: "3384308105 has no layer named '…Big…', so the mode the property change picks indexes an "
                            + "empty list and getLayer(undefined) is null: throws in WE too"),
        ExpectedFailure(key: "f629892e644b", check: .finite,
                        reason: "3453730450 'TY' angles read shared.wrx, which the same object's origin script sets in its "
                            + "first update; NaN on frame 0 is written in WE too (P3). Order within an object is P1's best guess"),
        ExpectedFailure(key: "f86e0df8a16e", check: .exception,
                        reason: "2963872291 has no '.mp3' sound layers, so clicking the Solid play button indexes an empty "
                            + "track list: throws in WE too"),
        ExpectedFailure(key: "7d3bc214624c", check: .change,
                        reason: "3546971487's scriptproperties clamp the scale to [2.7, 2.8] and the spectrum average stays "
                            + "below 2.7: constant in WE too"),
        ExpectedFailure(key: "a1b1d7b1a839", check: .change,
                        reason: "3187908708's asset (the same script as 7d3bc214624c) saves its scriptproperties in the "
                            + "old array form, which clamps the scale to [2.7, 2.8]: constant in WE too"),
        ExpectedFailure(key: "11844b104b6a", check: .change,
                        reason: "3677897732/3803728810 bind it to a constant authored as 0, which it multiplies by the "
                            + "audio level: constant in WE too"),
    ]

    // MARK: - Corpus

    func testEveryCorpusWallpaperReplays() throws {
        let index = SceneScriptCorpus.directory.appending(path: "index.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: index.path), "SceneScript corpus not present")
        let corpus = try SceneScriptCorpus.wallpapers()
        XCTAssertGreaterThanOrEqual(corpus.count, 43)

        let prelude = SceneScriptPrelude.load()
        XCTAssertNotNil(prelude.baseClasses)
        var rows: [String] = []
        var allFindings: [SceneScriptReplayChecks.Finding] = []
        var sites = 0
        var changed: [String] = [], removed: [String] = []
        for entry in corpus {
            let label = entry.label
            guard let directory = entry.directory else { continue }
            let state = SceneScriptCorpus.state(of: entry)
            if state == .removed {
                removed.append(label)
                continue
            }
            let wallpaper: SceneScriptReplayWallpaper
            do {
                wallpaper = try SceneScriptReplayWallpaper(directory: directory, id: entry.id)
            } catch {
                XCTFail("\(label): \(error)")
                continue
            }
            if state == .current {
                XCTAssertEqual(wallpaper.sites.count, entry.entries.count, "\(label): sites found vs corpus index")
            } else {
                changed.append(label)
            }
            sites += wallpaper.sites.count
            let options = SceneScriptReplayHarness.Options()
            let result = try SceneScriptReplayHarness(wallpaper: wallpaper, options: options).run(prelude: prelude)
            let findings = SceneScriptReplayChecks.findings(result, options: options)
            allFindings += findings
            rows.append(Self.row(label, result, findings))
            Self.assert(findings, expected: Self.expectedFailures, scope: Set(wallpaper.sites.map(\.hash) + [entry.id]),
                        label: label)
        }
        LibraryReport.attach("SceneScript corpus: library changes since index.json", SceneScriptCorpus.notes(changed: changed, removed: removed))
        let report = Self.report(rows: rows, findings: allFindings, sites: sites)
        XCTContext.runActivity(named: "SceneScript corpus replay") { activity in
            activity.add(XCTAttachment(string: report))
        }
        Self.writeReport(report)
    }

    /// Plan §4.6's reference scene: 3453730450 (71 sites, audio, cursor, `shared`). The whole replay
    /// (load and 600 frames) per iteration; the corpus report above has the per-frame numbers.
    func testMoonReplayPerformance() throws {
        let directory = try XCTUnwrap(Self.roots["owe"]).appending(path: "3453730450", directoryHint: .isDirectory)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: directory.path), "3453730450 not present")
        let wallpaper = try SceneScriptReplayWallpaper(directory: directory, id: "3453730450")
        let prelude = SceneScriptPrelude.load()
        measure(metrics: [XCTClockMetric()]) {
            do {
                _ = try SceneScriptReplayHarness(wallpaper: wallpaper).run(prelude: prelude)
            } catch {
                XCTFail("\(error)")
            }
        }
    }

    // MARK: - Reporting

    static func row(_ label: String, _ result: SceneScriptReplayHarness.Result,
                    _ findings: [SceneScriptReplayChecks.Finding]) -> String {
        let counts = Dictionary(grouping: findings, by: \.check).mapValues(\.count)
        let summary = SceneScriptReplayChecks.Check.allCases.compactMap { check in
            counts[check].map { "\(check.rawValue) \($0)" }
        }.joined(separator: ", ")
        let unsupported = result.unsupportedMembers.sorted().joined(separator: ", ")
        return String(format: "| %@ | %d | %.2f | %.3f | %.3f | %.3f | %.3f | %d | %d | %@ | %@ |", label,
                      result.sites.count, result.loadMilliseconds, result.meanFrameMilliseconds, result.percentile(0.5),
                      result.percentile(0.99), result.percentile(0.5, cpu: true), result.commandCount, result.createdLayers,
                      unsupported.isEmpty ? "-" : unsupported, summary.isEmpty ? "ok" : summary)
    }

    static func report(rows: [String], findings: [SceneScriptReplayChecks.Finding], sites: Int) -> String {
        var lines = ["SceneScript corpus replay: \(rows.count) wallpapers, \(sites) sites, \(findings.count) findings", "",
                     "| wallpaper | sites | load ms | mean ms/frame | p50 | p99 | CPU p50 | commands | created | stubs used | findings |",
                     "|---|---|---|---|---|---|---|---|---|---|---|"]
        lines += rows
        lines += ["", "Findings:"]
        lines += findings.map { "- \($0)" }
        return lines.joined(separator: "\n")
    }

    /// Writes the report where `OWE_REPLAY_REPORT` points (xcodebuild passes
    /// `TEST_RUNNER_OWE_REPLAY_REPORT`), for reading outside Xcode.
    static func writeReport(_ report: String) {
        guard let path = ProcessInfo.processInfo.environment["OWE_REPLAY_REPORT"], !path.isEmpty else { return }
        do {
            try report.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        } catch {
            XCTFail("Writing the replay report to \(path) failed: \(error)")
        }
    }

    /// Fails for every finding without an expectation; wraps each expected one in `XCTExpectFailure`
    /// so an entry whose finding is gone fails too. `scope` is what the run covered (script hashes
    /// and the wallpaper id): expectations outside it are not checked here.
    static func assert(_ findings: [SceneScriptReplayChecks.Finding], expected: [ExpectedFailure], scope: Set<String>,
                       label: String, file: StaticString = #filePath, line: UInt = #line) {
        var remaining = findings
        for expectation in expected where scope.contains(expectation.key) {
            let matched = remaining.filter { $0.key == expectation.key && $0.check == expectation.check }
            remaining.removeAll { $0.key == expectation.key && $0.check == expectation.check }
            XCTExpectFailure("\(label) \(expectation.key) \(expectation.check.rawValue): \(expectation.reason)") {
                XCTAssertTrue(matched.isEmpty, "\(label): \(matched.map(\.description).joined(separator: "; "))",
                              file: file, line: line)
            }
        }
        for finding in remaining {
            XCTFail("\(label): \(finding)", file: file, line: line)
        }
    }
}
