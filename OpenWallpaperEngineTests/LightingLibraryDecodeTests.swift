import XCTest
@testable import OpenWallpaperEngine

/// The library survey of docs/lighting-plan.md §1.5, rerun through the app's decoder: every scene
/// of the Workshop folder, OpenWallpaperStorage and WE's default projects (de-duplicated by
/// Workshop id, the Workshop copy first; `project.json` type "scene" only), its scene file read
/// loose or from its `.pkg`. Skipped when the library is absent (CI). A library that changed
/// fails: update the counts and the plan's survey together.
final class LightingLibraryDecodeTests: XCTestCase {
    private static let weRoot = "/Volumes/980Pro/Crossover/bottles/Steam Bottle/drive_c/Program Files (x86)/Steam/steamapps"
    static let roots = [URL(fileURLWithPath: "\(weRoot)/workshop/content/431960"),
                        URL(fileURLWithPath: "/Volumes/980Pro/OpenWallpaperStorage"),
                        URL(fileURLWithPath: "\(weRoot)/common/wallpaper_engine/projects/defaultprojects")]

    func testTheLibrarysLightsAndSettingsDecode() throws {
        let roots = Self.roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        try XCTSkipIf(roots.count < Self.roots.count, "wallpaper library not present")
        var seen = Set<String>()
        var scenes = 0
        var kinds: [WELightKind: Int] = [:]
        var lightConfigs = 0, hdr = 0, bloomHDR = 0
        for root in roots {
            for name in try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() {
                let directory = root.appending(path: name, directoryHint: .isDirectory)
                guard let project = Self.project(in: directory) else { continue }
                let workshopID = project["workshopid"].map { "\($0)" } ?? ""
                let key = workshopID.isEmpty || workshopID == "0" ? name : workshopID
                guard !seen.contains(key), !seen.contains(name) else { continue }
                seen.formUnion([key, name])
                guard (project["type"] as? String)?.lowercased() == "scene" else { continue }
                let file = project["file"] as? String ?? "scene.json"
                let data = try XCTUnwrap(Self.read(file, in: directory), "\(name): no \(file)")
                let scene: WEScene
                do {
                    scene = try decodeTolerant(WEScene.self, from: data)
                } catch {
                    XCTFail("\(name): \(error)")
                    continue
                }
                scenes += 1
                for object in scene.objects {
                    if let light = object.light { kinds[light.kind, default: 0] += 1 }
                }
                if scene.general.lightconfig != nil { lightConfigs += 1 }
                if scene.general.hdr == true { hdr += 1 }
                if scene.general.values[.bloomhdrstrength] != nil { bloomHDR += 1 }
            }
        }
        XCTAssertEqual(scenes, 106)
        XCTAssertEqual(kinds, [.tube: 4, .point: 3, .legacyPoint: 3, .spot: 1])
        XCTAssertEqual(lightConfigs, 3)
        XCTAssertEqual(hdr, 5)
        XCTAssertEqual(bloomHDR, 70)
    }

    /// `project.json`; nil for a folder without one. `try?`: an unreadable one isn't a wallpaper.
    private static func project(in directory: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: directory.appending(path: "project.json")) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.json5Allowed])) as? [String: Any]
    }

    /// A loose file wins over the same path inside a `.pkg`, as WE reads a wallpaper.
    private static func read(_ file: String, in directory: URL) -> Data? {
        if let loose = FileManager.default.contents(atPath: directory.appending(path: file).path) { return loose }
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "pkg" else { continue }
            do {
                if let data = try PKGParser(url: url).extractFile(named: file) { return data }
            } catch {
                XCTFail("\(url.path): \(error)")
            }
        }
        return nil
    }
}
