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
    static let revision = 2

    let compiler: ShaderCompiler
    let cacheDirectory: URL?
    private let lock = NSLock()
    private var memory: [String: TranslatedShaderVariant] = [:]

    init(compiler: ShaderCompiler, cacheDirectory: URL? = ShaderVariantTranslator.defaultCacheDirectory) {
        self.compiler = compiler
        self.cacheDirectory = cacheDirectory
    }

    static var defaultCacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "com.winddog.wallpaper-engine/shader-variants", directoryHint: .isDirectory)
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
        let key = Self.cacheKey(vertex: vertex, fragment: fragment, combos: combos)
        lock.lock()
        if let cached = memory[key] { lock.unlock(); return cached }
        lock.unlock()
        if let cached = loadFromDisk(key) {
            store(key, cached, persist: false)
            return cached
        }
        let translated = try translate(vertex: vertex, fragment: fragment, combos: combos)
        store(key, translated, persist: true)
        return translated
    }

    static func cacheKey(vertex: ShaderSource, fragment: ShaderSource, combos: [String: Int]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("\(revision)\u{0}".utf8))
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
        do {
            let vertexText = try compiler.preprocess(ShaderPrelude.text(for: .vertex, combos: combos) + vertex.text, stage: .vertex)
            let fragmentText = try compiler.preprocess(ShaderPrelude.text(for: .fragment, combos: combos) + fragment.text, stage: .fragment)
            let pair = ShaderPairRewriter.rewrite(vertex: ShaderPrelude.fixupAfterPreprocess(vertexText),
                                                  fragment: ShaderPrelude.fixupAfterPreprocess(fragmentText))
            let vertexOut = try compiler.compileToMSL(pair.vertex, stage: .vertex)
            let fragmentOut = try compiler.compileToMSL(pair.fragment, stage: .fragment)
            let layout = try Self.uniformLayout(from: fragmentOut.reflection) ?? Self.uniformLayout(from: vertexOut.reflection)
            return TranslatedShaderVariant(vertexMSL: vertexOut.msl, fragmentMSL: fragmentOut.msl, uniforms: layout,
                                           textureSlots: pair.textureSlots, attributes: pair.attributes, combos: combos)
        } catch {
            throw ShaderVariantError.translation(label, underlying: error)
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
            guard let name = member["name"] as? String, let offset = member["offset"] as? Int else {
                throw ShaderVariantError.reflection("member without name/offset in \(typeID)")
            }
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
        guard persist, let directory = cacheDirectory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(variant).write(to: directory.appending(path: "\(key).json"), options: .atomic)
        } catch {
            OWELog.error(.shader, "Could not cache shader variant \(key): \(error)")
        }
    }

    private func loadFromDisk(_ key: String) -> TranslatedShaderVariant? {
        guard let url = cacheDirectory?.appending(path: "\(key).json"),
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
