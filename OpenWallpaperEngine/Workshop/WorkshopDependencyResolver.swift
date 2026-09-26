//
//  WorkshopDependencyResolver.swift
//  Open Wallpaper Engine
//
//  Some wallpapers reuse fonts, effects, materials or models that live in a *different* Steam
//  Workshop item (an "asset pack"), referenced by paths like `effects/workshop/<id>/…`, or name one
//  in project.json's `dependency`. This finds those ids in a wallpaper (its package entries,
//  scene.json, materials and every other JSON it ships, and project.json), reports which aren't
//  installed, and links installed ones in so the loose-file loaders resolve them.
//

import Foundation

enum WorkshopDependencyResolver {
    /// Every other Workshop item the item in `directory` references.
    static func referencedWorkshopIds(inItemAt directory: URL) -> Set<String> {
        var ids = Set<String>()
        for pkg in WorkshopAssetResolver.packages(in: directory) {
            let parser: PKGParser
            do {
                parser = try PKGParser(url: pkg)
            } catch {
                OWELog.error(.workshop, "Can't scan \(pkg.path) for workshop dependencies: \(error)")
                continue
            }
            for entry in parser.fileList {
                ids.formUnion(WorkshopAssetResolver.referencedIds(in: entry))
                guard entry.lowercased().hasSuffix(".json"), let data = parser.extractFile(named: entry) else { continue }
                ids.formUnion(WorkshopAssetResolver.referencedIds(in: String(decoding: data, as: UTF8.self)))
            }
        }
        if let manifest = WallpaperPackageConverter.manifest(in: directory) {
            // Converted wallpapers no longer have the archive; the manifest lists its paths.
            for path in manifest.extractedFiles { ids.formUnion(WorkshopAssetResolver.referencedIds(in: path)) }
        }
        ids.formUnion(looseReferences(in: directory))
        ids.formUnion(projectDependencies(inItemAt: directory))
        ids.remove(directory.lastPathComponent)
        return ids
    }

    /// project.json's `dependency`: a single id (string or number) or a list of them.
    static func projectDependencies(inItemAt directory: URL) -> Set<String> {
        let url = directory.appending(path: "project.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        } catch {
            OWELog.error(.workshop, "Can't read \(url.path) for its dependency: \(error)")
            return []
        }
        guard let project = object as? [String: Any], let value = project["dependency"] else { return [] }
        let values: [Any] = (value as? [Any]) ?? [value]
        return Set(values.compactMap { item -> String? in
            let id = (item as? String) ?? (item as? NSNumber)?.stringValue
            guard let id, !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
            return id
        })
    }

    /// References in the item's loose files: folder names (`materials/workshop/<id>`) and the
    /// contents of its JSON files. Linked dependency folders are not followed.
    private static func looseReferences(in directory: URL) -> Set<String> {
        var ids = Set<String>()
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return ids }
        let base = directory.standardizedFileURL.path
        for case let url as URL in enumerator {
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count))
            ids.formUnion(WorkshopAssetResolver.referencedIds(in: relative + "/"))
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "json" else { continue }
            do {
                ids.formUnion(WorkshopAssetResolver.referencedIds(in: String(decoding: try Data(contentsOf: url), as: UTF8.self)))
            } catch {
                OWELog.error(.workshop, "Can't read \(url.path) for workshop dependencies: \(error)")
            }
        }
        return ids
    }

    /// The referenced ids no root has downloaded yet.
    static func missingWorkshopIds(for wallpaper: WEWallpaper,
                                   resolver: WorkshopAssetResolver = WorkshopAssetResolver(roots: WorkshopAssetResolver.defaultRoots())) -> Set<String> {
        referencedWorkshopIds(inItemAt: wallpaper.wallpaperDirectory).filter { !resolver.isInstalled($0) }
    }

    /// Links each installed dependency's category folder into the wallpaper
    /// (`<wallpaper>/effects/workshop/<id>` → `<item>/effects`), so the loose-file loaders find
    /// `effects/workshop/<id>/…` like any other file. Idempotent.
    static func linkInstalledDependencies(for wallpaper: WEWallpaper,
                                          resolver: WorkshopAssetResolver = WorkshopAssetResolver(roots: WorkshopAssetResolver.defaultRoots())) {
        let fm = FileManager.default
        for id in referencedWorkshopIds(inItemAt: wallpaper.wallpaperDirectory) {
            guard let item = resolver.itemDirectory(for: id) else { continue }
            let categories: [URL]
            do {
                categories = try fm.contentsOfDirectory(at: item, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            } catch {
                OWELog.error(.workshop, "Can't list workshop dependency \(item.path): \(error)")
                continue
            }
            for categorySource in categories {
                let linkParent = wallpaper.wallpaperDirectory.appending(path: categorySource.lastPathComponent).appending(path: "workshop")
                let linkPath = linkParent.appending(path: id)
                guard !fm.fileExists(atPath: linkPath.path) else { continue }
                do {
                    try fm.createDirectory(at: linkParent, withIntermediateDirectories: true)
                    try fm.createSymbolicLink(at: linkPath, withDestinationURL: categorySource)
                } catch {
                    OWELog.error(.workshop, "Failed to link workshop dependency \(id): \(error)")
                }
            }
        }
    }
}
