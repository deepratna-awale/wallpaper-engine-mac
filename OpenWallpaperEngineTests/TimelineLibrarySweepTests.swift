import XCTest
@testable import OpenWallpaperEngine

/// Every timeline of the local library (`animation` objects in every JSON file, `.pkg` contents
/// included) run through `SceneTimelineAnimation` and compared with the reference model's values in
/// `Tests/Fixtures/Timeline/library-expected.json` (`Scripts/timeline-reference.py library`), to
/// the fixture's tolerance.
///
/// The library is re-read here, so a wallpaper that changed or appeared fails: a timeline the
/// expectations don't list, one they list that is gone, or a shape the model doesn't know (an
/// option or keyframe key outside the known set, a mode other than loop, mirror or single). Then
/// rerun the script. Skipped when the library is absent (CI); `OWE_LIBRARY` (paths separated by
/// ':') replaces the two default roots.
final class TimelineLibrarySweepTests: XCTestCase {
    static var roots: [URL] {
        let paths = ProcessInfo.processInfo.environment["OWE_LIBRARY"].map { $0.split(separator: ":").map(String.init) }
            ?? ["/Volumes/980Pro/Crossover/bottles/Steam Bottle/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960",
                "/Volumes/980Pro/OpenWallpaperStorage"]
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// A timeline found in the library: `path` is the JSON path of its holder.
    struct Found {
        var item: String
        var file: String
        var path: [String]
        var holder: [String: SceneJSON]
        var animation: SceneJSON

        var owner: [String] { Array(path.dropLast()) }
        var key: String { path.last ?? "" }
        var id: String { "\(item) \(file) \(path.joined(separator: "/"))" }
        var parentKey: String? { animation[oracle: "options"]?[oracle: "parent"]?[oracle: "key"]?.oracleString }
    }

    func testEveryLibraryTimelineMatchesTheReferenceModel() throws {
        let roots = Self.roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        try XCTSkipIf(roots.isEmpty, "wallpaper library not present")
        let expectations = try TimelineOracle.load(Fixtures.url("Timeline/library-expected.json"))
        let tolerance = try TimelineOracle.float(XCTUnwrap(expectations[oracle: "tolerance"]))

        var scannedItems = Set<String>()
        let found = try Self.findTimelines(roots: roots, scannedItems: &scannedItems)
        for timeline in found {
            let problems = Self.shapeProblems(timeline.animation)
            XCTAssertTrue(problems.isEmpty, "\(timeline.id): shape the reference model doesn't cover: \(problems)")
        }
        let groups = Self.linkGroups(found)
        var byID: [String: [Found]] = [:]
        for group in groups { byID[Self.groupID(group)] = group }

        var matched = Set<String>(), timelines = 0, runs = 0
        for entry in try XCTUnwrap(expectations[oracle: "groups"]?.oracleArray) {
            let item = entry[oracle: "item"]?.oracleString ?? ""
            let file = entry[oracle: "file"]?.oracleString ?? ""
            let paths = (entry[oracle: "paths"]?.oracleArray ?? []).compactMap(\.oracleString)
            let id = "\(item) \(file) \(paths.joined(separator: " + "))"
            guard scannedItems.contains(item) else { continue }
            guard let group = byID[id] else {
                XCTFail("\(id): expected, but the library no longer has this timeline group; rerun Scripts/timeline-reference.py library")
                continue
            }
            matched.insert(id)
            let components = try (entry[oracle: "components"]?.oracleArray ?? []).map(TimelineOracle.int)
            let members = zip(group, components).map { timeline, width in
                TimelineOracle.Member(key: timeline.key, value: timeline.holder["value"], components: width,
                                      animation: timeline.animation)
            }
            timelines += members.count
            for run in try TimelineOracle.runs(entry[oracle: "runs"]) {
                runs += 1
                do {
                    if let mismatch = try TimelineOracle.check(run, members: members, tolerance: tolerance) {
                        XCTFail("\(id): \(mismatch)")
                    }
                } catch {
                    XCTFail("\(id): \(error)")
                }
            }
        }
        for id in byID.keys.sorted() where !matched.contains(id) {
            XCTFail("\(id): not in library-expected.json; rerun Scripts/timeline-reference.py library")
        }
        print("TimelineLibrarySweep: \(found.count) timelines in \(groups.count) clock groups, "
              + "\(timelines) compared over \(runs) runs")
    }

    // MARK: - The library walk (as the script's `library_files` and `find_animations`)

    /// Per root, per item: `.pkg` entries first, then loose files, each in sorted order; an
    /// (item, name) seen before, in this root or an earlier one, is skipped.
    static func findTimelines(roots: [URL], scannedItems: inout Set<String>) throws -> [Found] {
        var seen = Set<String>(), found: [Found] = []
        let fileManager = FileManager.default
        for root in roots {
            for item in try fileManager.contentsOfDirectory(atPath: root.path).sorted() {
                let base = root.appending(path: item, directoryHint: .isDirectory)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: base.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                scannedItems.insert(item)
                let files = (fileManager.enumerator(atPath: base.path)?.allObjects as? [String] ?? [])
                    .filter { path in
                        var directory: ObjCBool = false
                        return fileManager.fileExists(atPath: base.appending(path: path).path, isDirectory: &directory)
                            && !directory.boolValue
                    }
                    .sorted()
                for rel in files where rel.hasSuffix(".pkg") {
                    let package: PKGParser
                    do {
                        package = try PKGParser(url: base.appending(path: rel))
                    } catch {
                        XCTFail("\(item)/\(rel): \(error)")
                        continue
                    }
                    for name in package.fileList.sorted() where seen.insert("\(item)\u{0}\(name)").inserted {
                        guard name.hasSuffix(".json"), let data = package.extractFile(named: name) else { continue }
                        found += timelines(in: data, item: item, file: "\(rel)::\(name)")
                    }
                }
                for rel in files where !rel.hasSuffix(".pkg") && seen.insert("\(item)\u{0}\(rel)").inserted {
                    guard rel.hasSuffix(".json") else { continue }
                    found += timelines(in: try Data(contentsOf: base.appending(path: rel)), item: item, file: rel)
                }
            }
        }
        return found
    }

    private static func timelines(in data: Data, item: String, file: String) -> [Found] {
        // Only files that can hold one are decoded; the others are skipped whole.
        guard data.range(of: Data("\"animation\"".utf8)) != nil else { return [] }
        var body = data
        if body.starts(with: [0xEF, 0xBB, 0xBF]) { body = body.dropFirst(3) }
        // A file that isn't JSON isn't a scene document: the script skips it too.
        guard let document = try? JSONDecoder().decode(SceneJSON.self, from: body) else { return [] }
        var found: [Found] = []
        func walk(_ node: SceneJSON, _ path: [String]) {
            switch node {
            case .object(let object):
                if let animation = object["animation"], isTimeline(animation) {
                    found.append(Found(item: item, file: file, path: path, holder: object, animation: animation))
                }
                for (key, value) in object { walk(value, path + [key]) }
            case .array(let array):
                for (index, value) in array.enumerated() { walk(value, path + [String(index)]) }
            default:
                break
            }
        }
        walk(document, [])
        return found
    }

    private static func isTimeline(_ json: SceneJSON) -> Bool {
        guard let object = json.oracleObject else { return false }
        return object["options"] != nil || (0..<4).contains { object["c\($0)"] != nil }
    }

    /// Clock groups (§2.5): a timeline and the siblings (same file and owner) whose
    /// `options.parent.key` names its key. A timeline whose parent key names a sibling is in that
    /// sibling's group.
    static func linkGroups(_ timelines: [Found]) -> [[Found]] {
        var byOwner: [String: [Found]] = [:]
        for timeline in timelines {
            byOwner["\(timeline.item)\u{0}\(timeline.file)\u{0}\(timeline.owner.joined(separator: "/"))", default: []].append(timeline)
        }
        var groups: [[Found]] = []
        for siblings in byOwner.values {
            let keys = Set(siblings.map(\.key))
            for timeline in siblings {
                if let parent = timeline.parentKey, keys.contains(parent), parent != timeline.key { continue }
                let children = siblings.filter { $0.path != timeline.path && $0.parentKey == timeline.key }
                    .sorted { $0.key < $1.key }
                groups.append([timeline] + children)
            }
        }
        return groups
    }

    /// The group's identity as the expectations write it: owner path, then the children's paths.
    private static func groupID(_ group: [Found]) -> String {
        "\(group[0].item) \(group[0].file) \(group.map { $0.path.joined(separator: "/") }.joined(separator: " + "))"
    }

    // MARK: - Shapes the reference model knows

    static let animationKeys: Set<String> = ["c0", "c1", "c2", "c3", "options", "relative", "previewvalue"]
    static let optionKeys: Set<String> = ["fps", "length", "mode", "wraploop", "startpaused", "random", "name", "events",
                                          "parent", "children", "smoothing", "stiffness"]
    static let keyframeKeys: Set<String> = ["frame", "value", "back", "front", "step", "lockangle", "locklength"]
    static let handleKeys: Set<String> = ["enabled", "x", "y", "magic"]

    static func shapeProblems(_ animation: SceneJSON) -> [String] {
        guard let object = animation.oracleObject else { return ["not an object"] }
        var problems = object.keys.filter { !animationKeys.contains($0) }.sorted().map { "animation key '\($0)'" }
        guard let options = object["options"]?.oracleObject else { return problems + ["no options"] }
        problems += options.keys.filter { !optionKeys.contains($0) }.sorted().map { "option '\($0)'" }
        let mode = options["mode"]?.oracleString
        if !["loop", "mirror", "single"].contains(mode) { problems.append("mode \(options["mode"].map { "\($0)" } ?? "absent")") }
        if (options["fps"]?.oracleNumber ?? 0) <= 0 { problems.append("fps \(String(describing: options["fps"]))") }
        if (options["length"]?.oracleNumber ?? 0) <= 0 { problems.append("length \(String(describing: options["length"]))") }
        for index in 0..<4 {
            for keyframe in object["c\(index)"]?.oracleArray ?? [] {
                guard let fields = keyframe.oracleObject else {
                    problems.append("c\(index) keyframe \(keyframe)")
                    continue
                }
                problems += fields.keys.filter { !keyframeKeys.contains($0) }.sorted().map { "keyframe key '\($0)'" }
                for side in ["back", "front"] {
                    let handle = fields[side]?.oracleObject ?? [:]
                    problems += handle.keys.filter { !handleKeys.contains($0) }.sorted().map { "handle key '\($0)'" }
                }
            }
        }
        return problems
    }
}
