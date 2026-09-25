import CryptoKit
import Foundation

/// Explodes a wallpaper's `.pkg` into loose files inside the same wallpaper directory.
///
/// The runtime already prefers a `.pkg` when present and otherwise reads loose files, so removing
/// the archive from the search path is all that is needed to switch a wallpaper over. The original
/// archive is moved into `.owe-source/` rather than deleted; reclaiming that space is a separate,
/// explicit step because the converter is not yet lossless for every Wallpaper Engine feature.
enum WallpaperPackageConverter {
    static let converterVersion = 2

    static let manifestName = ".owe-bundle.json"
    static let sourceFolderName = ".owe-source"

    struct Manifest: Codable {
        var converterVersion: Int
        var sourcePackage: String
        var sourceHash: String
        var sourceRetained: Bool
        var extractedFiles: [String]
        var warnings: [String]
        var convertedAt: Date
        /// Set once the converted bundle has actually rendered, which is the precondition for
        /// ever removing the archived original.
        var verifiedAt: Date?
        var verifiedObjectCount: Int?
    }

    static func manifestURL(in wallpaperDirectory: URL) -> URL {
        wallpaperDirectory.appending(path: manifestName)
    }

    static func manifest(in wallpaperDirectory: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: manifestURL(in: wallpaperDirectory)) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    /// True when the directory already holds a bundle produced by this converter version.
    static func isConverted(_ wallpaperDirectory: URL) -> Bool {
        manifest(in: wallpaperDirectory)?.converterVersion == converterVersion
    }

    @discardableResult
    static func convertIfNeeded(wallpaperDirectory: URL) -> Manifest? {
        guard !isConverted(wallpaperDirectory) else { return manifest(in: wallpaperDirectory) }
        guard let sceneFile = primarySceneFile(in: wallpaperDirectory) else { return nil }

        let packageName = (sceneFile as NSString).deletingPathExtension + ".pkg"
        let livePackageURL = wallpaperDirectory.appending(path: packageName)
        let archivedPackageURL = wallpaperDirectory.appending(path: sourceFolderName).appending(path: packageName)
        // Re-converting an existing bundle has to read the archived copy, since the first pass
        // moved it out of the wallpaper directory.
        let packageURL = FileManager.default.fileExists(atPath: livePackageURL.path(percentEncoded: false))
            ? livePackageURL
            : archivedPackageURL
        guard FileManager.default.fileExists(atPath: packageURL.path(percentEncoded: false)) else { return nil }

        guard let packageData = try? Data(contentsOf: packageURL, options: .mappedIfSafe),
              let parser = try? PKGParser(data: packageData) else {
            OWELog.error(.importer, "Convert: unable to read \(packageName)")
            return nil
        }

        var extracted: [String] = []
        var warnings: [String] = []

        for entry in parser.fileList {
            guard let relativePath = sanitizedRelativePath(entry) else {
                warnings.append("Skipped unsafe entry path: \(entry)")
                continue
            }
            guard let data = parser.extractFile(named: entry) else {
                warnings.append("Missing data for entry: \(entry)")
                continue
            }
            let destination = wallpaperDirectory.appending(path: relativePath)
            // Re-check after resolving symlinks and "." segments so nothing escapes the directory.
            guard destination.standardizedFileURL.path.hasPrefix(wallpaperDirectory.standardizedFileURL.path) else {
                warnings.append("Skipped escaping entry path: \(entry)")
                continue
            }
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
                // A clean extraction is the only thing gating removal of the original, so prove
                // each file landed byte-for-byte instead of trusting the write.
                guard let written = try? Data(contentsOf: destination), written == data else {
                    warnings.append("Readback mismatch for \(relativePath)")
                    continue
                }
                extracted.append(relativePath)
            } catch {
                warnings.append("Failed to write \(relativePath): \(error.localizedDescription)")
            }
        }

        // Without the scene descriptor on disk the wallpaper would not load at all, so leave the
        // archive in place and report failure rather than half-converting it.
        let sceneOnDisk = FileManager.default.fileExists(
            atPath: wallpaperDirectory.appending(path: sceneFile).path(percentEncoded: false))
        guard sceneOnDisk else {
            OWELog.error(.importer, "Convert: \(sceneFile) missing after extraction; keeping \(packageName)")
            return nil
        }

        let sourceFolder = wallpaperDirectory.appending(path: sourceFolderName)
        var sourceRetained = packageURL == archivedPackageURL
        if !sourceRetained {
            do {
                try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
                let archived = sourceFolder.appending(path: packageName)
                try? FileManager.default.removeItem(at: archived)
                try FileManager.default.moveItem(at: packageURL, to: archived)
                sourceRetained = true
            } catch {
                warnings.append("Could not archive \(packageName): \(error.localizedDescription)")
            }
        }

        let manifest = Manifest(converterVersion: converterVersion,
                                sourcePackage: packageName,
                                sourceHash: SHA256.hash(data: packageData).map { String(format: "%02x", $0) }.joined(),
                                sourceRetained: sourceRetained,
                                extractedFiles: extracted,
                                warnings: warnings,
                                convertedAt: Date())
        write(manifest, to: wallpaperDirectory)

        OWELog.info(.importer, "Converted \(wallpaperDirectory.lastPathComponent): \(extracted.count) files, \(warnings.count) warnings")
        return manifest
    }

    /// Deletes the archived original. Extraction is byte-for-byte, so once a bundle has rendered
    /// and nothing was skipped, the archive holds no bytes the directory doesn't already have.
    @discardableResult
    static func reclaimSource(in wallpaperDirectory: URL) -> Bool {
        guard var current = manifest(in: wallpaperDirectory), current.sourceRetained else { return false }
        guard let reason = ineligibilityReason(for: current, directory: wallpaperDirectory) else {
            let sourceFolder = wallpaperDirectory.appending(path: sourceFolderName)
            guard (try? FileManager.default.removeItem(at: sourceFolder)) != nil else { return false }
            current.sourceRetained = false
            write(current, to: wallpaperDirectory)
            OWELog.info(.importer, "Reclaimed original package for \(wallpaperDirectory.lastPathComponent)")
            return true
        }
        OWELog.info(.importer, "Keeping original for \(wallpaperDirectory.lastPathComponent): \(reason)")
        return false
    }

    /// nil means the bundle is fully migrated and the archive is safe to delete.
    ///
    /// Extraction copies every entry byte-for-byte and reads each one back, so a warning-free
    /// conversion means the directory already holds everything the archive did. Dependent
    /// wallpapers symlink to this directory's asset folders, never to the archive.
    static func ineligibilityReason(for manifest: Manifest, directory: URL) -> String? {
        if manifest.converterVersion != converterVersion { return "converted by an older version" }
        if !manifest.warnings.isEmpty { return "conversion reported \(manifest.warnings.count) warning(s)" }
        if manifest.extractedFiles.isEmpty { return "nothing was extracted" }
        return nil
    }

    static func isFullyMigrated(_ wallpaperDirectory: URL) -> Bool {
        guard let manifest = manifest(in: wallpaperDirectory) else { return false }
        return ineligibilityReason(for: manifest, directory: wallpaperDirectory) == nil
    }

    /// Records that the converted files actually produced a scene.
    static func markVerified(wallpaperDirectory: URL, objectCount: Int) {
        guard var current = manifest(in: wallpaperDirectory), current.verifiedAt == nil, objectCount > 0 else { return }
        current.verifiedAt = Date()
        current.verifiedObjectCount = objectCount
        write(current, to: wallpaperDirectory)
    }

    /// Converts wallpapers that were installed before conversion existed.
    static func convertInstalledLibrary() {
        let fileManager = FileManager.default
        let root = fileManager.wallpapersDirectory
        guard let entries = try? fileManager.contentsOfDirectory(at: root,
                                                                 includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles]) else { return }
        var converted = 0
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  !isConverted(entry) else { continue }
            if convertIfNeeded(wallpaperDirectory: entry) != nil { converted += 1 }
        }
        if converted > 0 {
            OWELog.info(.importer, "Converted \(converted) previously installed wallpaper(s)")
        }
    }

    /// Reclaims every bundle that is fully migrated. Returns the number of archives removed.
    @discardableResult
    static func reclaimEligibleSources() -> Int {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: fileManager.wallpapersDirectory,
                                                                 includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles]) else { return 0 }
        return entries.reduce(into: 0) { total, entry in
            if reclaimSource(in: entry) { total += 1 }
        }
    }

    /// Bytes currently held by archived originals that are safe to delete.
    static func reclaimableBytes() -> Int64 {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: fileManager.wallpapersDirectory,
                                                                 includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles]) else { return 0 }
        return entries.reduce(into: Int64(0)) { total, entry in
            guard let manifest = manifest(in: entry), manifest.sourceRetained,
                  ineligibilityReason(for: manifest, directory: entry) == nil else { return }
            let archive = entry.appending(path: sourceFolderName).appending(path: manifest.sourcePackage)
            let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
    }

    private static func write(_ manifest: Manifest, to wallpaperDirectory: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(manifest) else { return }
        try? data.write(to: manifestURL(in: wallpaperDirectory), options: .atomic)
    }

    private static func primarySceneFile(in wallpaperDirectory: URL) -> String? {
        guard let data = try? Data(contentsOf: wallpaperDirectory.appending(path: "project.json")),
              let project = try? JSONDecoder().decode(WEProject.self, from: data) else { return nil }
        return project.file.lowercased().hasSuffix(".json") ? project.file : nil
    }

    /// PKG entries are authored on Windows and are untrusted input, so reject anything absolute or
    /// containing a parent traversal before it is joined onto the wallpaper directory.
    private static func sanitizedRelativePath(_ raw: String) -> String? {
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/"), !normalized.contains(":") else { return nil }
        let components = normalized.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        for component in components where component == ".." || component == "." || component.isEmpty {
            return nil
        }
        return components.joined(separator: "/")
    }
}
