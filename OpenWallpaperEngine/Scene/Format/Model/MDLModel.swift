import Foundation
import simd

/// A Wallpaper Engine `.mdl` model: the meshes of its `MDLV` part and the sections after it
/// (docs/models-plan.md §1). Static models, animated models and Puppet Warp rigs all use it.
/// `MDLReader` reads every version WE's runtime reads.
struct MDLModel: Equatable {
    /// A section after the meshes (`MDLV` 13 and later), where it sat in the file.
    struct Section: Equatable {
        var tag: String
        /// The tag's offset.
        var offset: Int
        /// The stored end: the next tag's offset.
        var end: Int
        /// Where reading it stopped (equal to `end` in every library file). WE skips to `end`.
        var parsedEnd: Int
        /// A tag WE doesn't read.
        var skipped: Bool
    }

    /// `MDLVnnnn`.
    var tag: String
    /// The `nnnn` of the tag (`atoi(tag + 4)`).
    var version: Int
    /// The vertex format of every mesh before `MDLV` 15.
    var legacyFormat: UInt32
    var materialsPerMesh: UInt32
    var meshes: [MDLMesh]
    var sections: [Section] = []
    var skeleton: MDLSkeleton?
    /// The `MDLA` version, with `animations`.
    var animationsVersion: Int?
    var animations: [MDLAnimation]?
    var attachments: [MDLAttachment]?
    /// One entry per mesh, when the file has an `MDMP0001` section.
    var morphTargets: [MDLMorphTargets]?
    /// `MDLE0002`: one local matrix per bone, an alternate pose (the writer's `referencepose` [I]).
    var referencePose: [simd_float4x4]?
    /// Where WE's reader stops: after the meshes before `MDLV` 13, else after the empty tag.
    var end: Int
    /// Bytes after `end` (old writers left 0x00 or 0xCD fill); WE never reads them.
    var trailingByteCount: Int

    /// The model's box as WE builds it (`MDLBounds.union`).
    var bounds: MDLBounds { MDLBounds.union(of: meshes.map(\.bounds)) }

    /// The clip with that `id` (what an animation layer's `animation` names).
    func animation(id: UInt64) -> MDLAnimation? { animations?.first { $0.id == id } }

    /// The attachment with exactly that name (a scene object's `attachment`).
    func attachment(named name: String) -> MDLAttachment? { attachments?.first { $0.name == name } }
}

extension MDLModel {
    init(data: Data) throws {
        self = try MDLReader.read(data)
    }

    init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// The model at `path`, from the wallpaper's package when it has the entry (the order the
    /// scene loader reads assets in), else the loose file in `directory`.
    static func load(path: String, package: PKGParser?, directory: URL) throws -> MDLModel {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        if let package {
            let entry = package.fileList.first { $0.replacingOccurrences(of: "\\", with: "/") == normalized }
            if let entry, let data = package.extractFile(named: entry) {
                return try MDLModel(data: data)
            }
        }
        let url = directory.appending(path: normalized)
        guard FileManager.default.fileExists(atPath: url.path) else { throw MDLError.missing(path: path) }
        return try MDLModel(contentsOf: url)
    }
}
