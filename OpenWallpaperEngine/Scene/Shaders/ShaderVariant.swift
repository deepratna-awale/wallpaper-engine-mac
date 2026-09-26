import Foundation
import CryptoKit

/// One member of the `WEUniforms` block, as SPIRV-Cross laid it out (std140).
struct UniformMember: Codable, Equatable {
    let name: String
    let type: String
    let offset: Int
    /// Elements in an array member (1 for scalars/vectors/matrices).
    let count: Int
    /// Bytes between array elements; std140 rounds every element up to 16.
    let arrayStride: Int
    /// Bytes between matrix columns (16 for std140).
    let matrixStride: Int
}

struct UniformLayout: Codable, Equatable {
    let size: Int
    let members: [String: UniformMember]
}

/// A vertex/fragment pair translated to MSL for one resolved combo set.
struct TranslatedShaderVariant: Codable {
    let vertexMSL: String
    let fragmentMSL: String
    /// nil when the pair has no loose uniforms.
    let uniforms: UniformLayout?
    /// `g_TextureN` slots used; texture(N) and sampler(N) in MSL.
    let textureSlots: [Int]
    /// Vertex attribute name → location.
    let attributes: [String: Int]
    /// Combos the variant was compiled with (defaults included).
    let combos: [String: Int]
}

enum ShaderVariantError: Error, CustomStringConvertible {
    case translation(String, underlying: Error)
    case reflection(String)

    var description: String {
        switch self {
        case .translation(let shader, let error): return "\(shader): \(error)"
        case .reflection(let message): return "reflection: \(message)"
        }
    }
}

/// Resolves combos, translates a pair and caches the result on disk.
///
/// Variants are compiled lazily: scenes reference a few hundred (shader, combo) pairs out of
/// hundreds of thousands possible, so nothing is precompiled.
final class ShaderVariantTranslator {
    /// Bump whenever translated output for the same input can change.
    static let revision = 7

    let compiler: ShaderCompiler
    /// Root of the disk cache; variants go into its `generationDirectory`.
    let cacheDirectory: URL?
    /// `<cacheDirectory>/<generation>`: every variant this revision and compiler can produce.
    let generationDirectory: URL?
    /// The compiler's backend, versions and options (`ShaderCompiler.cacheFingerprint`) at creation;
    /// names `generationDirectory`. Cache keys read the compiler's current one.
    let toolchainFingerprint: String
    /// Where the source a compiler step rejected is written, one file per shader and stage: the
    /// compiler's line numbers refer to it, not to the WE file. nil writes nothing.
    let failureDirectory: URL?
    private let lock = NSLock()
    private var memory: [String: TranslatedShaderVariant] = [:]

    static let defaultFailureDirectory = URL(fileURLWithPath: "/tmp/owe-failed-shaders", isDirectory: true)

    init(compiler: ShaderCompiler, cacheDirectory: URL? = ShaderVariantTranslator.defaultCacheDirectory,
         failureDirectory: URL? = ShaderVariantTranslator.defaultFailureDirectory) {
        self.compiler = compiler
        self.cacheDirectory = cacheDirectory
        self.failureDirectory = failureDirectory
        toolchainFingerprint = compiler.cacheFingerprint
        let generation = Self.generation(toolchain: toolchainFingerprint)
        generationDirectory = cacheDirectory?.appending(path: generation, directoryHint: .isDirectory)
        if let cacheDirectory {
            // Off the caller's thread: a stale generation can hold thousands of files.
            DispatchQueue.global(qos: .utility).async {
                Self.pruneStaleGenerations(in: cacheDirectory, keeping: generation)
            }
        }
    }

    static var defaultCacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "com.winddog.wallpaper-engine/shader-variants", directoryHint: .isDirectory)
    }

    /// Names the cache subdirectory of one translator revision and compiler. Variants of any other
    /// can never be read again (their keys include both), so a change starts a new directory and
    /// the old one is deleted (`pruneStaleGenerations`) instead of growing the cache forever.
    static func generation(toolchain: String) -> String {
        let digest = SHA256.hash(data: Data(toolchain.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "r\(revision)-\(digest)"
    }

    /// How long another generation is kept after its last use. Two builds used side by side
    /// (a development build next to the installed app) each keep theirs.
    static let staleGenerationAge: TimeInterval = 7 * 24 * 3600

    /// Deletes variants in `root` from before generations (flat `<key>.json` files) and other
    /// generations unused for `staleGenerationAge`, and marks `keeping` as used now.
    static func pruneStaleGenerations(in root: URL, keeping: String, now: Date = Date()) {
        let fileManager = FileManager.default
        // Optional: no directory yet means nothing to prune.
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where name != keeping {
            let url = root.appending(path: name)
            if !name.hasSuffix(".json") {
                guard name.hasPrefix("r") else { continue } // not ours
                // Optional: without a date the directory is left alone.
                let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                guard let modified, now.timeIntervalSince(modified) > staleGenerationAge else { continue }
            }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                OWELog.error(.shader, "Could not delete the stale shader variant cache \(name): \(error)")
            }
        }
        let current = root.appending(path: keeping).path
        guard fileManager.fileExists(atPath: current) else { return }
        do {
            try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: current)
        } catch {
            OWELog.error(.shader, "Could not mark the shader variant cache \(keeping) as used: \(error)")
        }
    }

    /// Variants cached in `root`, over every generation.
    static func cachedVariantCount(in root: URL) -> Int {
        let fileManager = FileManager.default
        // Optional: no directory yet means an empty cache.
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        return names.reduce(0) { count, name in
            if name.hasSuffix(".json") { return count + 1 }
            let inner = (try? fileManager.contentsOfDirectory(atPath: root.appending(path: name).path)) ?? [] // not a directory: none
            return count + inner.filter { $0.hasSuffix(".json") }.count
        }
    }

    /// Combo values for a pass: declared defaults < material < effect pass < instance, plus sampler
    /// combos (`"combo":"MASK"`) switched on for bound texture slots.
    static func resolveCombos(vertex: ShaderSource, fragment: ShaderSource,
                              overrides: [[String: Int]], boundTextureSlots: Set<Int>) -> [String: Int] {
        var combos: [String: Int] = [:]
        for declaration in vertex.combos + fragment.combos where combos[declaration.name] == nil {
            combos[declaration.name] = declaration.defaultValue
        }
        for sampler in vertex.samplers + fragment.samplers {
            guard let combo = sampler.combo?.uppercased(), let slot = sampler.textureSlot else { continue }
            combos[combo] = boundTextureSlots.contains(slot) ? 1 : (combos[combo] ?? 0)
        }
        for layer in overrides {
            for (name, value) in layer { combos[name.uppercased()] = value }
        }
        return combos
    }

    func variant(vertex: ShaderSource, fragment: ShaderSource, combos: [String: Int]) throws -> TranslatedShaderVariant {
        // Read per call: the in-process compiler hands over to the process compiler after a hang.
        let toolchain = compiler.cacheFingerprint
        let key = Self.cacheKey(vertex: vertex, fragment: fragment, combos: combos, toolchain: toolchain)
        lock.lock()
        if let cached = memory[key] { lock.unlock(); return cached }
        lock.unlock()
        if let cached = loadFromDisk(key) {
            store(key, cached, persist: false)
            return cached
        }
        let translated = try translate(vertex: vertex, fragment: fragment, combos: combos)
        // A hand-over mid-translation made it with both compilers: it belongs under neither key.
        if compiler.cacheFingerprint == toolchain { store(key, translated, persist: true) }
        return translated
    }

    static func cacheKey(vertex: ShaderSource, fragment: ShaderSource, combos: [String: Int],
                         toolchain: String = "") -> String {
        var hasher = SHA256()
        hasher.update(data: Data("\(revision)\u{0}\(toolchain)\u{0}".utf8))
        hasher.update(data: Data(vertex.text.utf8))
        hasher.update(data: Data("\u{0}".utf8))
        hasher.update(data: Data(fragment.text.utf8))
        for (name, value) in combos.sorted(by: { $0.key < $1.key }) {
            hasher.update(data: Data("\u{0}\(name)=\(value)".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func translate(vertex: ShaderSource, fragment: ShaderSource,
                           combos: [String: Int]) throws -> TranslatedShaderVariant {
        let label = "\(vertex.path) + \(fragment.path)"
        // The input of the step running now, kept for `recordFailure`.
        var step: (source: ShaderSource, text: String)?
        do {
            step = (vertex, ShaderPrelude.text(for: .vertex, combos: combos, analysis: vertex.preludeAnalysis) + vertex.text(combos: combos))
            let vertexText = try compiler.preprocess(step!.text, stage: .vertex)
            step = (fragment, ShaderPrelude.text(for: .fragment, combos: combos, analysis: fragment.preludeAnalysis) + fragment.text(combos: combos))
            let fragmentText = try compiler.preprocess(step!.text, stage: .fragment)
            let pair = ShaderPairRewriter.rewrite(vertex: ShaderPrelude.fixupAfterPreprocess(vertexText),
                                                  fragment: ShaderPrelude.fixupAfterPreprocess(fragmentText))
            step = (vertex, pair.vertex)
            let vertexOut = try compiler.compileToMSL(pair.vertex, stage: .vertex)
            step = (fragment, pair.fragment)
            let fragmentOut = try compiler.compileToMSL(pair.fragment, stage: .fragment)
            step = nil
            let layout = try Self.uniformLayout(from: fragmentOut.reflection) ?? Self.uniformLayout(from: vertexOut.reflection)
            return TranslatedShaderVariant(vertexMSL: vertexOut.msl, fragmentMSL: fragmentOut.msl, uniforms: layout,
                                           textureSlots: pair.textureSlots, attributes: pair.attributes, combos: combos)
        } catch {
            if let step { recordFailure(step.source, text: step.text, error: error) }
            throw ShaderVariantError.translation(label, underlying: error)
        }
    }

    /// Writes the text a compiler step rejected to `failureDirectory`, with the error after it
    /// (not before, which would shift the line numbers it quotes).
    private func recordFailure(_ source: ShaderSource, text: String, error: Error) {
        guard let failureDirectory else { return }
        let suffix = "." + source.stage.rawValue
        let name = source.path.replacingOccurrences(of: "/", with: "_") + (source.path.hasSuffix(suffix) ? "" : suffix)
        let url = failureDirectory.appending(path: name)
        let trailer = "\(error)".split(separator: "\n").map { "// \($0)" }.joined(separator: "\n")
        do {
            try FileManager.default.createDirectory(at: failureDirectory, withIntermediateDirectories: true)
            try (text + (text.hasSuffix("\n") ? "" : "\n") + trailer + "\n").write(to: url, atomically: true, encoding: .utf8)
            OWELog.error(.shader, "Shader \(source.path) failed to translate; its source is at \(url.path)")
        } catch {
            OWELog.error(.shader, "Could not write the failed shader \(url.path): \(error)")
        }
    }

    /// Reads the `WEUniforms` block from SPIRV-Cross `--reflect` JSON. Both stages declare the same
    /// block, so either one describes it; a stage that doesn't use any uniform may omit it.
    static func uniformLayout(from reflection: Data) throws -> UniformLayout? {
        guard let root = try JSONSerialization.jsonObject(with: reflection) as? [String: Any] else {
            throw ShaderVariantError.reflection("not a JSON object")
        }
        // The block is found by its type name; the ubo entry's own name is the (empty) instance name.
        guard let ubos = root["ubos"] as? [[String: Any]],
              let types = root["types"] as? [String: [String: Any]],
              let block = ubos.first(where: { ubo in
                  (ubo["type"] as? String).flatMap { types[$0]?["name"] as? String } == ShaderPairRewriter.uniformBlockName }),
              let typeID = block["type"] as? String,
              let members = types[typeID]?["members"] as? [[String: Any]] else { return nil }
        var result: [String: UniformMember] = [:]
        for member in members {
            guard let reflected = member["name"] as? String, let offset = member["offset"] as? Int else {
                throw ShaderVariantError.reflection("member without name/offset in \(typeID)")
            }
            // Material constants bind by WE's name, not the one the prelude gave a reserved word.
            let name = GLSLReservedWords.originalName(reflected)
            let count = (member["array"] as? [Int])?.first ?? 1
            result[name] = UniformMember(name: name, type: member["type"] as? String ?? "",
                                         offset: offset, count: max(count, 1),
                                         arrayStride: member["array_stride"] as? Int ?? 0,
                                         matrixStride: member["matrix_stride"] as? Int ?? 0)
        }
        return UniformLayout(size: block["block_size"] as? Int ?? 0, members: result)
    }

    // MARK: - Cache

    private func store(_ key: String, _ variant: TranslatedShaderVariant, persist: Bool) {
        lock.lock()
        memory[key] = variant
        lock.unlock()
        guard persist, let directory = generationDirectory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(variant).write(to: directory.appending(path: "\(key).json"), options: .atomic)
        } catch {
            OWELog.error(.shader, "Could not cache shader variant \(key): \(error)")
        }
    }

    private func loadFromDisk(_ key: String) -> TranslatedShaderVariant? {
        guard let url = generationDirectory?.appending(path: "\(key).json"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(TranslatedShaderVariant.self, from: Data(contentsOf: url))
        } catch {
            OWELog.error(.shader, "Discarding unreadable cached shader variant \(key): \(error)")
            try? FileManager.default.removeItem(at: url) // corrupt entry; retranslating is the recovery
            return nil
        }
    }
}
