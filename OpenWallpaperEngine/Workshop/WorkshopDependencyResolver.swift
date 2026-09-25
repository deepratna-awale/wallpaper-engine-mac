//
//  WorkshopDependencyResolver.swift
//  Open Wallpaper Engine
//
//  Some scene wallpapers reuse effects/materials that live in a *different* Steam Workshop item
//  (an "asset pack"), referenced by paths like "effects/workshop/1234567/someeffect/effect.json".
//  This scans a wallpaper's scene package for those references, reports which referenced workshop
//  IDs aren't installed locally, and links already-installed ones in by symlinking so the existing
//  PKG/loose-file loaders resolve them without any changes.
//

import Foundation

enum WorkshopDependencyResolver {
    /// One "<category>/workshop/<id>/..." reference found in a scene package.
    struct Reference: Hashable {
        let category: String
        let workshopId: String
    }

    private static let pathPattern = try! NSRegularExpression(
        pattern: #"(effects|materials|particles|shaders|models|textures)[\\/]workshop[\\/](\d{5,})[\\/]"#)

    /// All external workshop items this wallpaper's scene package references, excluding itself.
    static func referencedDependencies(for wallpaper: WEWallpaper) -> Set<Reference> {
        guard wallpaper.project.type.caseInsensitiveCompare("scene") == .orderedSame else { return [] }
        let ownId = wallpaper.project.workshopid?.rawValue ?? wallpaper.wallpaperDirectory.lastPathComponent

        var references = Set<Reference>()
        let sceneFile = wallpaper.project.file
        let pkgURL = wallpaper.wallpaperDirectory.appending(path: (sceneFile as NSString).deletingPathExtension + ".pkg")
        if let parser = try? PKGParser(url: pkgURL) {
            for path in parser.fileList {
                references.formUnion(dependencies(in: path))
            }
        } else if let manifest = WallpaperPackageConverter.manifest(in: wallpaper.wallpaperDirectory) {
            // Converted wallpapers no longer have the archive in place; the manifest lists the
            // same paths the package did.
            for path in manifest.extractedFiles {
                references.formUnion(dependencies(in: path))
            }
        }
        if let projectData = try? Data(contentsOf: wallpaper.wallpaperDirectory.appending(path: "project.json")),
           let projectText = String(data: projectData, encoding: .utf8) {
            references.formUnion(dependencies(in: projectText))
        }
        return references.filter { $0.workshopId != ownId }
    }

    /// The subset of referenced workshop IDs that aren't present in the local wallpaper library yet.
    static func missingWorkshopIds(for wallpaper: WEWallpaper) -> Set<String> {
        let referenced = Set(referencedDependencies(for: wallpaper).map(\.workshopId))
        guard !referenced.isEmpty else { return [] }
        return referenced.filter { !isInstalled($0) }
    }

    /// Symlinks every already-installed dependency's matching asset folder into this wallpaper's own
    /// directory (e.g. `<wallpaper>/effects/workshop/<id>` -> `<library>/<id>/effects`), so paths like
    /// "effects/workshop/<id>/name/effect.json" resolve exactly like a normal loose file. Safe to call
    /// repeatedly; it does nothing once a link already exists.
    static func linkInstalledDependencies(for wallpaper: WEWallpaper) {
        let fm = FileManager.default
        for reference in referencedDependencies(for: wallpaper) {
            guard isInstalled(reference.workshopId) else { continue }
            let categorySource = fm.wallpapersDirectory.appending(path: reference.workshopId).appending(path: reference.category)
            guard fm.fileExists(atPath: categorySource.path) else { continue }

            let linkParent = wallpaper.wallpaperDirectory.appending(path: reference.category).appending(path: "workshop")
            let linkPath = linkParent.appending(path: reference.workshopId)
            guard !fm.fileExists(atPath: linkPath.path) else { continue }
            do {
                try fm.createDirectory(at: linkParent, withIntermediateDirectories: true)
                try fm.createSymbolicLink(at: linkPath, withDestinationURL: categorySource)
            } catch {
                OWELog.error(.workshop, "Failed to link workshop dependency \(reference.workshopId): \(error)")
            }
        }
    }

    private static func isInstalled(_ workshopId: String) -> Bool {
        FileManager.default.fileExists(atPath: FileManager.default.wallpapersDirectory
            .appending(path: workshopId).appending(path: "project.json").path)
    }

    private static func dependencies(in text: String) -> Set<Reference> {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var references = Set<Reference>()
        for match in pathPattern.matches(in: text, range: range) {
            guard let categoryRange = Range(match.range(at: 1), in: text),
                  let idRange = Range(match.range(at: 2), in: text) else { continue }
            references.insert(Reference(category: String(text[categoryRange]), workshopId: String(text[idRange])))
        }
        return references
    }
}
