import Foundation
import CryptoKit

enum SceneShaderTranslator {
    /// Resolved once per launch. Bundled copies win so a packaged build works without Homebrew;
    /// otherwise fall back to the usual install locations and finally the user's PATH.
    struct Toolchain {
        let glslang: String
        let spirvCross: String
    }

    private static let toolchainLock = NSLock()
    nonisolated(unsafe) private static var resolvedToolchain: Toolchain??

    private static let searchDirectories: [String] = [
        Bundle.main.bundleURL.appending(path: "Contents/Resources/shader-tools").path,
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/usr/bin"
    ]

    /// Bumped when the translation pipeline changes. It is part of every translation stamp, so
    /// both translated and unsupported shaders are redone against the new pipeline instead of
    /// serving output from an older translator forever.
    private static let pipelineRevision = "5"

    /// A translation is current only if both its source and the translator that produced it match.
    private static func translationStamp(for source: Data) -> String {
        let hash = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        return "\(pipelineRevision):\(hash)"
    }

    static var toolchain: Toolchain? {
        toolchainLock.lock()
        defer { toolchainLock.unlock() }
        if let resolvedToolchain { return resolvedToolchain }
        let resolved = locateToolchain()
        resolvedToolchain = .some(resolved)
        if let resolved {
            OWELog.info(.shader, "Shader toolchain: \(resolved.glslang) + \(resolved.spirvCross)")
        } else {
            OWELog.error(.shader, "Shader toolchain unavailable; Workshop effects will fall back to native shaders only. Install with: brew install glslang spirv-cross")
        }
        return resolved
    }

    static func invalidateToolchainCache() {
        toolchainLock.lock()
        resolvedToolchain = nil
        metalCompiler = nil
        toolchainLock.unlock()
    }

    /// `xcrun metal`/`metallib` ship with Xcode, not the standalone command line tools, so this is
    /// best-effort: without it the runtime falls back to compiling the .metal source each launch.
    nonisolated(unsafe) private static var metalCompiler: (metal: String, metallib: String)??

    private static func resolveMetalCompiler() -> (metal: String, metallib: String)? {
        toolchainLock.lock()
        defer { toolchainLock.unlock() }
        if let metalCompiler { return metalCompiler }
        func locateViaXcrun(_ tool: String) -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["-f", tool]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return nil }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let path, FileManager.default.isExecutableFile(atPath: path) else { return nil }
            return path
        }
        let resolved = locateViaXcrun("metal").flatMap { metal in
            locateViaXcrun("metallib").map { (metal: metal, metallib: $0) }
        }
        metalCompiler = .some(resolved)
        if resolved == nil {
            OWELog.info(.shader, "Metal compiler unavailable; shaders will be compiled from source at runtime")
        }
        return resolved
    }

    /// spirv-cross declares uniforms as `constant T&` on the entry point but emits helper
    /// functions taking `thread const T&`, which Metal rejects as an address-space mismatch.
    /// Re-point those parameters at the constant address space.
    private static func fixupConstantAddressSpaces(at url: URL) {
        guard let original = try? String(contentsOf: url, encoding: .utf8) else { return }
        let pattern = #"constant\s+([A-Za-z_][A-Za-z0-9_]*)\s*&\s*([A-Za-z_][A-Za-z0-9_]*)\s*\[\[buffer"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let text = original as NSString
        var globals = Set<String>()
        for match in regex.matches(in: original, range: NSRange(location: 0, length: text.length)) {
            let type = text.substring(with: match.range(at: 1))
            let name = text.substring(with: match.range(at: 2))
            globals.insert("\(type)|\(name)")
        }
        guard !globals.isEmpty else { return }
        var patched = original
        for global in globals {
            let parts = global.split(separator: "|").map(String.init)
            guard parts.count == 2 else { continue }
            patched = patched.replacingOccurrences(of: "thread const \(parts[0])& \(parts[1])",
                                                   with: "constant \(parts[0])& \(parts[1])")
        }
        guard patched != original else { return }
        try? patched.write(to: url, atomically: true, encoding: .utf8)
    }

    /// glslang's `--auto-map-bindings` hands every element of an array uniform its own binding, so
    /// a shader with a `float[32]` spectrum ends up with indices past Metal's limit of 30 even
    /// though it only has a handful of buffers. Renumbering densely keeps the declaration order
    /// that the non-array shaders already get.
    private static func fixupBufferIndices(at url: URL) {
        guard let original = try? String(contentsOf: url, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"\[\[buffer\((\d+)\)\]\]"#) else { return }
        let text = original as NSString
        let matches = regex.matches(in: original, range: NSRange(location: 0, length: text.length))
        var order: [Int] = []
        for match in matches {
            let index = Int(text.substring(with: match.range(at: 1))) ?? 0
            if !order.contains(index) { order.append(index) }
        }
        guard let highest = order.max(), highest > 30 else { return }
        let remapped = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        var patched = original
        for match in matches.reversed() {
            let index = Int(text.substring(with: match.range(at: 1))) ?? 0
            guard let new = remapped[index] else { continue }
            patched = (patched as NSString).replacingCharacters(in: match.range, with: "[[buffer(\(new))]]")
        }
        try? patched.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The vendored cache ships translated `.metal` files without their libraries, and their GLSL
    /// sources are not shipped, so the translation pass never sees them and nothing else would
    /// ever compile them.
    static func backfillMissingLibraries(in cacheDirectory: URL) {
        guard let enumerator = FileManager.default.enumerator(at: cacheDirectory,
                                                              includingPropertiesForKeys: nil) else { return }
        var pending: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "metal" {
            let library = url.appendingPathExtension("metallib")
            let unsupported = url.appendingPathExtension("unsupported")
            guard !FileManager.default.fileExists(atPath: library.path),
                  !FileManager.default.fileExists(atPath: unsupported.path) else { continue }
            pending.append(url)
        }
        guard !pending.isEmpty else { return }
        DispatchQueue.global(qos: .background).async {
            var compiled = 0
            for metal in pending {
                fixupConstantAddressSpaces(at: metal)
                fixupBufferIndices(at: metal)
                if compileMetalLibrary(for: metal) {
                    compiled += 1
                } else {
                    try? "\(pipelineRevision):backfill"
                        .write(to: metal.appendingPathExtension("unsupported"), atomically: true, encoding: .utf8)
                }
            }
            OWELog.info(.shader, "Backfilled \(compiled)/\(pending.count) shader librar(ies) from cache")
        }
    }

    /// Produces a sibling `.metallib` so the renderer can mmap it instead of compiling MSL.
    @discardableResult
    static func compileMetalLibrary(for metalURL: URL) -> Bool {
        guard let tools = resolveMetalCompiler() else { return false }
        let libraryURL = metalURL.appendingPathExtension("metallib")
        let temporaryDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let airURL = temporaryDirectory.appending(path: "shader.air")
        guard run(tools.metal, ["-c", metalURL.path, "-o", airURL.path]),
              run(tools.metallib, [airURL.path, "-o", libraryURL.path]) else {
            try? FileManager.default.removeItem(at: libraryURL)
            return false
        }
        return true
    }

    private static func locateToolchain() -> Toolchain? {
        guard let glslang = locate(["glslangValidator", "glslang"]),
              let spirvCross = locate(["spirv-cross"]) else { return nil }
        return Toolchain(glslang: glslang, spirvCross: spirvCross)
    }

    private static func locate(_ names: [String]) -> String? {
        let fileManager = FileManager.default
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in searchDirectories + pathDirectories {
            for name in names {
                let candidate = (directory as NSString).appendingPathComponent(name)
                if fileManager.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    static func translatePackageShaders(in wallpaperDirectory: URL) {
        guard let tools = toolchain else { return }
        let (glslang, spirvCross) = (tools.glslang, tools.spirvCross)
        guard let projectData = try? Data(contentsOf: wallpaperDirectory.appending(path: "project.json")),
              let project = try? JSONDecoder().decode(WEProject.self, from: projectData) else { return }
        let packageURL = wallpaperDirectory.appending(path: (project.file as NSString).deletingPathExtension + ".pkg")
        guard let package = try? PKGParser(url: packageURL) else { return }

        let cacheDirectory = wallpaperDirectory.appending(path: ".open-wallpaper-engine/shaders")
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        for path in package.fileList where path.hasSuffix(".frag") || path.hasSuffix(".vert") {
            guard let source = package.extractFile(named: path),
                  let stage = path.hasSuffix(".frag") ? "frag" : "vert" as String? else { continue }
            let outputName = path.replacingOccurrences(of: "/", with: "_") + ".metal"
            let outputURL = cacheDirectory.appending(path: outputName)
            // Hash-gated rather than existence-gated: Workshop items update their PKG in place,
            // so a plain fileExists check would serve stale Metal forever.
            let hash = translationStamp(for: source)
            let hashURL = outputURL.appendingPathExtension("sha256")
            if FileManager.default.fileExists(atPath: outputURL.path),
               (try? String(contentsOf: hashURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == hash {
                continue
            }
            if translate(source: source, path: path, stage: stage, package: package,
                         glslang: glslang, spirvCross: spirvCross, outputURL: outputURL) {
                try? hash.write(to: hashURL, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Editor-only shaders that never render in a wallpaper: previews, Direct3D HLSL, and brushes.
    private static func isEditorOnlyShader(_ path: String) -> Bool {
        ["/preview/", "/previewvhs/", "/HLSL/"].contains { path.contains($0) }
            || path.contains("editorpaintbrush")
    }

    /// Drops cached translations of editor-only shaders left behind by builds that still translated
    /// them. Their names collide with the real shaders' when the catalog indexes the cache, so
    /// leaving them can serve the wrong program. Only those are touched: package translations share
    /// per-wallpaper cache directories and are not this pass's to remove. A pass that found no
    /// sources (the bundled cache ships without GLSL) removes nothing.
    private static func removeOrphanedTranslations(in cacheDirectory: URL, keeping outputs: Set<String>) {
        guard !outputs.isEmpty,
              let names = try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path) else { return }
        let sidecarSuffixes = [".metallib", ".sha256", ".unsupported", ".reflection.json"]
        var removed = 0
        for name in names {
            var output = name
            if let suffix = sidecarSuffixes.first(where: { name.hasSuffix($0) }) {
                output = String(name.dropLast(suffix.count))
            }
            // Output names are source paths with "/" flattened to "_".
            guard output.hasSuffix(".metal"), !outputs.contains(output),
                  isEditorOnlyShader("/" + output.replacingOccurrences(of: "_", with: "/") + "/") else { continue }
            if (try? FileManager.default.removeItem(at: cacheDirectory.appending(path: name))) != nil {
                removed += 1
            }
        }
        if removed > 0 {
            OWELog.info(.shader, "Removed \(removed) orphaned shader cache file(s) from \(cacheDirectory.path)")
        }
    }

    static func translateSharedShaders(in assetsDirectory: URL, cacheDirectory: URL) {
        guard let tools = toolchain else { return }
        let (glslang, spirvCross) = (tools.glslang, tools.spirvCross)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        var pendingLibraryCompiles: [(metal: URL, marker: URL, contents: String)] = []
        var currentOutputs = Set<String>()
        // `shaders/` holds the shared runtime shaders (fur, puppet warp, volumetrics) and
        // `zcompat/` per-wallpaper compatibility variants, both of which effects alone miss.
        let searchRoots = ["effects", "shaders", "zcompat"].map { assetsDirectory.appending(path: $0) }
        for root in searchRoots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator {
                let extensionName = url.pathExtension.lowercased()
                guard extensionName == "frag" || extensionName == "vert" else { continue }
                let relativePath = url.path.replacingOccurrences(of: assetsDirectory.path + "/", with: "")
                guard !isEditorOnlyShader(relativePath) else { continue }
                guard let source = try? Data(contentsOf: url) else { continue }
                let outputName = relativePath.replacingOccurrences(of: "/", with: "_") + ".metal"
                let outputURL = cacheDirectory.appending(path: outputName)
                currentOutputs.insert(outputName)
                let hash = translationStamp(for: source)
                let hashURL = outputURL.appendingPathExtension("sha256")
                // A handful of shaders cannot be expressed in Metal (e.g. more uniform buffers
                // than its 31 slots). Retrying them every launch costs a process spawn each and
                // buries real failures in the log.
                let unsupportedURL = outputURL.appendingPathExtension("unsupported")
                let unsupportedMarker = hash
                if (try? String(contentsOf: unsupportedURL, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) == unsupportedMarker { continue }
                if (try? String(contentsOf: hashURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == hash {
                    // Already translated. Any missing .metallib is backfilled after this pass so
                    // shader compilation never blocks catalog loading or first render.
                    if !FileManager.default.fileExists(atPath: outputURL.appendingPathExtension("metallib").path) {
                        pendingLibraryCompiles.append((outputURL, unsupportedURL, unsupportedMarker))
                    } else {
                        try? FileManager.default.removeItem(at: unsupportedURL)
                    }
                    continue
                }
                if translateShared(source: source, path: relativePath, stage: extensionName,
                                   assetsDirectory: assetsDirectory, glslang: glslang,
                                   spirvCross: spirvCross, outputURL: outputURL) {
                    try? hash.write(to: hashURL, atomically: true, encoding: .utf8)
                    // A shader that used to fail may translate after a pipeline change; leaving the
                    // marker behind would keep reporting it as unsupported.
                    try? FileManager.default.removeItem(at: unsupportedURL)
                    // Without this a freshly translated shader has no library until the *next*
                    // launch, when the hash-match branch above finally notices it missing.
                    pendingLibraryCompiles.append((outputURL, unsupportedURL, unsupportedMarker))
                } else {
                    try? unsupportedMarker.write(to: unsupportedURL, atomically: true, encoding: .utf8)
                }
            }
        }
        removeOrphanedTranslations(in: cacheDirectory, keeping: currentOutputs)
        guard !pendingLibraryCompiles.isEmpty else { return }
        DispatchQueue.global(qos: .background).async {
            var compiled = 0
            for pending in pendingLibraryCompiles {
                fixupConstantAddressSpaces(at: pending.metal)
                fixupBufferIndices(at: pending.metal)
                if compileMetalLibrary(for: pending.metal) {
                    compiled += 1
                    try? FileManager.default.removeItem(at: pending.marker)
                } else {
                    try? pending.contents.write(to: pending.marker, atomically: true, encoding: .utf8)
                }
            }
            let failed = pendingLibraryCompiles.count - compiled
            OWELog.info(.shader, "Precompiled \(compiled) shader librar(ies) in the background"
                + (failed > 0 ? "; \(failed) unsupported by Metal" : ""))
        }
    }

    @discardableResult
    private static func translateShared(source: Data, path: String, stage: String,
                                        assetsDirectory: URL, glslang: String,
                                        spirvCross: String, outputURL: URL) -> Bool {
        guard !path.contains("/HLSL/") else { return false }
        guard var text = String(data: source, encoding: .utf8) else { return false }
        let directory = (path as NSString).deletingLastPathComponent
        while let range = text.range(of: #"#include\s+\""#, options: .regularExpression) {
            let remainder = text[range.upperBound...]
            guard let end = remainder.firstIndex(of: "\"") else { return false }
            let name = String(remainder[..<end])
            let candidate = assetsDirectory.appending(path: directory).appending(path: name)
            let include: String
            if let decoded = try? String(contentsOf: candidate, encoding: .utf8) {
                include = decoded
            } else if let decoded = try? String(contentsOf: assetsDirectory.appending(path: "shaders/\(name)"), encoding: .utf8) {
                include = decoded
            } else if name == "common.h" {
                include = "#define float2 vec2\n#define float3 vec3\n#define float4 vec4\n#define saturate(x) clamp(x, 0.0, 1.0)\n"
            } else if name == "common_blending.h" {
                include = "vec3 ApplyBlending(int mode, vec3 base, vec3 blend, float amount) { return mix(base, blend, clamp(amount, 0.0, 1.0)); }\n"
            } else {
                return false
            }
            text.replaceSubrange(range.lowerBound...end, with: include)
        }
        text = text.replacingOccurrences(of: "#version 330 core", with: "")
        text = text.replacingOccurrences(of: "varying", with: stage == "frag" ? "in" : "out")
        text = text.replacingOccurrences(of: "attribute", with: "in")
        text = text.replacingOccurrences(of: "gl_FragColor", with: "out_FragColor")
        text = text.replacingOccurrences(of: "CAST2", with: "vec2")
        text = text.replacingOccurrences(of: "CAST3X3", with: "mat3")
        text = text.replacingOccurrences(of: "CAST3", with: "vec3")
        text = text.replacingOccurrences(of: "CAST4", with: "vec4")
        text = text.replacingOccurrences(of: "CASTF", with: "float")
        text = text.replacingOccurrences(of: "CASTU", with: "uint")
        text = text.replacingOccurrences(of: "CASTI", with: "int")
        text = text.replacingOccurrences(of: "frac", with: "fract")
        text = text.replacingOccurrences(of: "ddx", with: "dFdx")
        text = text.replacingOccurrences(of: "ddy", with: "dFdy")
        text = text.replacingOccurrences(of: "atan2", with: "atan")
        text = text.replacingOccurrences(of: "gl_ViewportIndex", with: "we_ViewportIndex")
        text = text.replacingOccurrences(of: #"\bsample\b"#, with: "sampleValue", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(\bvec3\s+\w+\s*=\s*texSample2D\([^;]+\))\s*;"#, with: "$1.rgb;", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(\bfloat\s+\w+\s*=\s*texSample2D\([^;]+\))\s*;"#, with: "$1.r;", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*#require\s+[^\n]+$"#, with: "", options: .regularExpression)
        // The header below owns these constants; a second, differently-rounded definition from
        // common.h is a glslang redefinition error.
        text = text.replacingOccurrences(of: #"(?m)^\s*#define\s+M_PI(_2|_HALF)?\s+[^\n]+$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*in\s+uint\s+gl_(InstanceID|VertexID)\s*;\s*$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"([0-9]+\.[0-9]{9})[0-9]+"#, with: "$1", options: .regularExpression)
        var uniforms: [String] = []
        var seenUniforms: Set<String> = []
        text = text.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("uniform sampler2D "), trimmed.contains(";") else { return true }
            if seenUniforms.insert(trimmed).inserted { uniforms.append(trimmed) }
            return false
        }.joined(separator: "\n")
        let rotateHelper = text.range(of: #"\bvec2\s+rotateVec2\s*\("#, options: .regularExpression) == nil
            ? "vec2 rotateVec2(vec2 value, float angle) { float s = sin(angle); float c = cos(angle); return vec2(value.x * c - value.y * s, value.x * s + value.y * c); }"
            : ""
        // Wallpaper Engine's common header provides these; shaders call them without declaring them,
        // and redefining one the source already has would be a compile error.
        let rgb2hsvHelper = text.range(of: #"\bvec3\s+rgb2hsv\s*\("#, options: .regularExpression) == nil
            ? "vec3 rgb2hsv(vec3 c) { vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0); vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g)); vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r)); float d = q.x - min(q.w, q.y); float e = 1.0e-10; return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x); }"
            : ""
        let hsv2rgbHelper = text.range(of: #"\bvec3\s+hsv2rgb\s*\("#, options: .regularExpression) == nil
            ? "vec3 hsv2rgb(vec3 c) { vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0); vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www); return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y); }"
            : ""
        let header = """
        #version 450
        #define texSample2D texture
        #define texSample2DLod textureLod
        #define saturate(x) clamp(x, 0.0, 1.0)
        #define frac(x) fract(x)
        #ifndef M_PI
        #define M_PI 3.14159265359
        #endif
        #ifndef M_PI_HALF
        #define M_PI_HALF 1.57079632679
        #endif
        // Wallpaper Engine's common.h defines M_PI_2 as 2π, not π/2; shaders rely on that value.
        #ifndef M_PI_2
        #define M_PI_2 6.28318530718
        #endif
        #ifndef M_PI_4
        #define M_PI_4 0.78539816339
        #endif
        #ifndef M_1_PI
        #define M_1_PI 0.31830988618
        #endif
        #define MASK 0
        #define MODE 0
        #define VARIATION 0
        #define CLAMP 0
        #define REPEAT 0
        #define BONECOUNT 1
        #define BLENDROWCOUNT 1
        #define INSTANCECOUNT 2
        vec4 mul(vec4 value, mat4 matrix) { return matrix * value; }
        vec4 mul(mat4 matrix, vec4 value) { return matrix * value; }
        vec3 mul(vec3 value, mat3 matrix) { return matrix * value; }
        vec3 mul(mat3 matrix, vec3 value) { return matrix * value; }
        mat3 mul(mat3 left, mat3 right) { return left * right; }
        vec2 pow(vec2 value, float exponent) { return pow(value, vec2(exponent)); }
        vec3 pow(vec3 value, float exponent) { return pow(value, vec3(exponent)); }
        vec4 pow(vec4 value, float exponent) { return pow(value, vec4(exponent)); }
        vec2 max(float left, vec2 right) { return max(vec2(left), right); }
        vec3 max(float left, vec3 right) { return max(vec3(left), right); }
        vec4 max(float left, vec4 right) { return max(vec4(left), right); }
        // Declaring any overload of a built-in stops glslang from converting int arguments when
        // matching the built-in itself, so HLSL-style calls like pow(x, 4) or max(0, x) need these.
        float pow(float value, int exponent) { return pow(value, float(exponent)); }
        vec2 pow(vec2 value, int exponent) { return pow(value, vec2(exponent)); }
        vec3 pow(vec3 value, int exponent) { return pow(value, vec3(exponent)); }
        vec4 pow(vec4 value, int exponent) { return pow(value, vec4(exponent)); }
        float max(int left, float right) { return max(float(left), right); }
        float max(float left, int right) { return max(left, float(right)); }
        vec2 max(int left, vec2 right) { return max(vec2(left), right); }
        vec3 max(int left, vec3 right) { return max(vec3(left), right); }
        vec4 max(int left, vec4 right) { return max(vec4(left), right); }
        vec2 rotateVec2(vec4 value, float angle) { float s = sin(angle); float c = cos(angle); return vec2(value.x * c - value.y * s, value.x * s + value.y * c); }
        vec3 PerformLighting_V1(vec3 worldPosition, vec3 color, vec3 normal, vec3 viewDirection, vec3 specularTint, vec3 ambient, float roughness, float metallic) {
            float diffuse = max(dot(normalize(normal), normalize(viewDirection)), 0.0);
            return color * (ambient + vec3(diffuse)) + specularTint * metallic * (1.0 - roughness);
        }
        \(rotateHelper)
        \(rgb2hsvHelper)
        \(hsv2rgbHelper)
        #define GLSL 1
        """
        let output = stage == "frag" ? "layout(location = 0) out vec4 out_FragColor;\n" : ""
        let comboDefines = text.components(separatedBy: .newlines).compactMap { line -> String? in
            guard line.contains("[COMBO]"),
                  let start = line.firstIndex(of: "{"),
                  let end = line.lastIndex(of: "}"),
                  let data = String(line[start...end]).data(using: .utf8),
                  let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let combo = metadata["combo"] as? String else { return nil }
            let value = (metadata["default"] as? NSNumber)?.stringValue ?? "0"
            return "#ifndef \(combo)\n#define \(combo) \(value)\n#endif"
        }.joined(separator: "\n")
        let shaderSource = header + "\n" + comboDefines + "\n" + uniforms.joined(separator: "\n") + "\n" + output + text
        let temporaryDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let glslURL = temporaryDirectory.appendingPathComponent("shader.\(stage)")
        let spirvURL = temporaryDirectory.appendingPathComponent("shader.spv")
        guard (try? shaderSource.write(to: glslURL, atomically: true, encoding: .utf8)) != nil else { return false }
            guard run(glslang, ["-G", "--auto-map-locations", "--auto-map-bindings", "-S", stage, "-o", spirvURL.path, glslURL.path]),
              run(spirvCross, ["--msl", "--msl-version", "230", "--output", outputURL.path, spirvURL.path]) else {
            // Keep the preprocessed source: the compiler's line numbers refer to it, not the
            // original .frag, so it is the only way to act on a translation failure.
            let dump = URL(fileURLWithPath: "/tmp/owe-failed-shaders")
                .appending(path: path.replacingOccurrences(of: "/", with: "_") + ".\(stage)")
            try? FileManager.default.createDirectory(at: dump.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? shaderSource.write(to: dump, atomically: true, encoding: .utf8)
            NSLog("[ShaderTranslator] Failed to translate shared shader %@ (preprocessed source at %@)",
                  path, dump.path)
            return false
        }
        fixupConstantAddressSpaces(at: outputURL)
        fixupBufferIndices(at: outputURL)
        SceneShaderReflection.parse(source: source).writeSidecar(for: outputURL)
        DispatchQueue.global(qos: .background).async { compileMetalLibrary(for: outputURL) }
        NSLog("[ShaderTranslator] Cached shared shader %@", outputURL.lastPathComponent)
        return true
    }

    @discardableResult
    private static func translate(source: Data, path: String, stage: String, package: PKGParser,
                                  glslang: String, spirvCross: String, outputURL: URL) -> Bool {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let glslURL = temporaryDirectory.appending(path: "shader.") .appendingPathExtension(stage)
        let spirvURL = temporaryDirectory.appending(path: "shader.spv")
        guard let expanded = expandIncludes(in: source, path: path, stage: stage, package: package),
              let compatibilitySource = String(data: expanded, encoding: .utf8)?.data(using: .utf8) else { return false }
        try? compatibilitySource.write(to: glslURL, options: .atomic)
        guard run(glslang, ["-G", "--auto-map-locations", "--auto-map-bindings", "-S", stage, "-o", spirvURL.path, glslURL.path]),
              run(spirvCross, ["--msl", "--msl-version", "230", "--output", outputURL.path, spirvURL.path]) else {
            NSLog("[ShaderTranslator] Failed to translate %@", path)
            return false
        }
        fixupConstantAddressSpaces(at: outputURL)
        SceneShaderReflection.parse(source: source).writeSidecar(for: outputURL)
        compileMetalLibrary(for: outputURL)
        NSLog("[ShaderTranslator] Cached %@", outputURL.lastPathComponent)
        return true
    }

    private static func expandIncludes(in source: Data, path: String, stage: String, package: PKGParser) -> Data? {
        guard var text = String(data: source, encoding: .utf8) else { return nil }
        let directory = (path as NSString).deletingLastPathComponent
        while let range = text.range(of: #"#include ""#, options: .regularExpression) {
            let remainder = text[range.upperBound...]
            guard let end = remainder.firstIndex(of: "\"") else { return nil }
            let name = String(remainder[..<end])
            let candidate = directory.isEmpty ? name : "\(directory)/\(name)"
            let includeText: String
            if name == "common_blending.h" {
                includeText = commonBlendingSource
            } else if name == "common.h" {
                includeText = commonSource
            } else if let include = package.extractFile(named: candidate)
                ?? package.extractFile(named: "shaders/\(name)")
                ?? package.extractFile(named: "\(candidate).h")
                ?? package.extractFile(named: "shaders/\(name).h"),
                      let decoded = String(data: include, encoding: .utf8) {
                includeText = decoded
            } else {
                NSLog("[ShaderTranslator] Unsupported include %@ in %@", name, path)
                return nil
            }
            let fullRange = range.lowerBound...end
            text.replaceSubrange(fullRange, with: includeText)
        }
        text = text.replacingOccurrences(of: "#version 330 core", with: "")
        text = text.replacingOccurrences(of: "varying", with: stage == "frag" ? "in" : "out")
        text = text.replacingOccurrences(of: "attribute", with: "in")
        text = text.replacingOccurrences(of: "gl_FragColor", with: "out_FragColor")
        text = text.replacingOccurrences(of: "CAST2", with: "vec2")
        text = text.replacingOccurrences(of: "CAST3X3", with: "mat3")
        text = text.replacingOccurrences(of: "CAST3", with: "vec3")
        text = text.replacingOccurrences(of: "CAST4", with: "vec4")
        text = text.replacingOccurrences(of: "frac", with: "fract")
        text = text.replacingOccurrences(of: #"([0-9]+\.[0-9]{9})[0-9]+"#, with: "$1", options: .regularExpression)
        var uniformLocation = 0
        text = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("uniform "), !trimmed.contains("sampler"),
                  !trimmed.hasPrefix("uniform layout") else { return String(line) }
            defer { uniformLocation += 1 }
            return "layout(location = \(uniformLocation)) \(line)"
        }.joined(separator: "\n")
        let header = """
        #version 450
        #define texSample2D texture
        #define texSample2DLod textureLod
        #define saturate(x) clamp(x, 0.0, 1.0)
        #define frac(x) fract(x)
        #define M_PI 3.14159
        #define MASK 0
        #define MODE 0
        #define VARIATION 0
        #define CLAMP 0
        #define REPEAT 0
        vec4 mul(vec4 value, mat4 matrix) { return matrix * value; }
        vec2 rotateVec2(vec2 value, float angle) { float s = sin(angle); float c = cos(angle); return vec2(value.x * c - value.y * s, value.x * s + value.y * c); }
        #define CAST3(x) vec3(x)
        #define AUDIOPROCESSING 0
        #define MASK 0
        #define PULSEALPHA 0
        #define PULSECOLOR 0
        #define BLENDMODE 0
        #define BACKGROUND 0
        #define GLSL 1
        """
        let output = stage == "frag" ? "layout(location = 0) out vec4 out_FragColor;\n" : ""
        return (header + output + text).data(using: .utf8)
    }

    private static let commonBlendingSource = """
    vec3 ApplyBlending(int mode, vec3 base, vec3 blend, float amount) {
        return mix(base, blend, clamp(amount, 0.0, 1.0));
    }
    """

    private static let commonSource = """
    #define int2 ivec2
    #define int3 ivec3
    #define int4 ivec4
    #define float2 vec2
    #define float3 vec3
    #define float4 vec4
    """

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        do {
            try process.run()
        } catch {
            NSLog("[ShaderTranslator] Failed to launch %@: %@", executable, error.localizedDescription)
            return false
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                ?? "no compiler output"
            NSLog("[ShaderTranslator] %@ %@\n%@", executable, arguments.joined(separator: " "), output)
        }
        return process.terminationStatus == 0
    }
}