import Foundation

enum SceneShaderTranslator {
    private static let compilerCandidates = [
        ("/opt/homebrew/bin/glslangValidator", "/opt/homebrew/bin/spirv-cross"),
        ("/usr/local/bin/glslangValidator", "/usr/local/bin/spirv-cross")
    ]

    static func translatePackageShaders(in wallpaperDirectory: URL) {
        guard let (glslang, spirvCross) = compilerCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.0) && FileManager.default.isExecutableFile(atPath: $0.1)
        }) else {
            NSLog("[ShaderTranslator] GLSL tools unavailable; skipping translation")
            return
        }
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
            guard !FileManager.default.fileExists(atPath: outputURL.path) else { continue }
            translate(source: source, path: path, stage: stage, package: package,
                      glslang: glslang, spirvCross: spirvCross, outputURL: outputURL)
        }
    }

    private static func translate(source: Data, path: String, stage: String, package: PKGParser,
                                  glslang: String, spirvCross: String, outputURL: URL) {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let glslURL = temporaryDirectory.appending(path: "shader.") .appendingPathExtension(stage)
        let spirvURL = temporaryDirectory.appending(path: "shader.spv")
        guard let expanded = expandIncludes(in: source, path: path, stage: stage, package: package),
              let compatibilitySource = String(data: expanded, encoding: .utf8)?.data(using: .utf8) else { return }
        try? compatibilitySource.write(to: glslURL, options: .atomic)
        guard run(glslang, ["-G", "--auto-map-locations", "--auto-map-bindings", "-S", stage, "-o", spirvURL.path, glslURL.path]),
              run(spirvCross, ["--msl", "--msl-version", "230", "--output", outputURL.path, spirvURL.path]) else {
            NSLog("[ShaderTranslator] Failed to translate %@", path)
            return
        }
        NSLog("[ShaderTranslator] Cached %@", outputURL.lastPathComponent)
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
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}