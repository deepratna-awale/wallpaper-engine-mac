import SwiftUI

private struct SceneInspectorItem: Identifiable {
    let id: String
    let name: String
    let kind: String
    let sourcePath: String
    let materialPath: String?
    let texturePaths: [String]
    let shaderPaths: [String]
    let rawObject: String
    let rawMaterial: String?
    let rawParticle: String?
}

private struct SceneInspectorTexture: Identifiable {
    let id: String
    let path: String
    let image: NSImage
}

private final class SceneInspectorModel: ObservableObject {
    @Published var items: [SceneInspectorItem] = []
    @Published var errorMessage: String?
    @Published var decodedTextures: [SceneInspectorTexture] = []
    @Published var decodedItemID: String?
    @Published var loadingItemID: String?

    private let directory: URL
    private let package: PKGParser?
    private var textureLoadGeneration = 0

    init(wallpaper: WEWallpaper) {
        directory = wallpaper.wallpaperDirectory
        let scenePath = wallpaper.project.file
        let packageURL = directory.appending(path: (scenePath as NSString).deletingPathExtension + ".pkg")
        package = try? PKGParser(url: packageURL)

        func data(_ path: String) -> Data? {
            package?.extractFile(named: path) ?? (try? Data(contentsOf: directory.appending(path: path)))
        }
        func rawJSON(_ path: String) -> String? {
            guard let data = data(path),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let formatted = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return nil }
            return String(data: formatted, encoding: .utf8)
        }
        guard let sceneData = data(scenePath),
              let scene = try? JSONDecoder().decode(WEScene.self, from: sceneData),
              let sceneJSON = try? JSONSerialization.jsonObject(with: sceneData) as? [String: Any],
              let rawObjects = sceneJSON["objects"] as? [[String: Any]] else {
            errorMessage = "Unable to read the scene definition."
            return
        }

        items = scene.objects.enumerated().map { index, object in
            let rawObject = rawObjects.indices.contains(index) ? prettyJSON(rawObjects[index]) : "{}"
            if let imagePath = object.image {
                let model: WEModel? = data(imagePath).flatMap { try? JSONDecoder().decode(WEModel.self, from: $0) }
                let materialPath = model?.material
                let material: WEMaterial? = materialPath.flatMap { data($0) }.flatMap { try? JSONDecoder().decode(WEMaterial.self, from: $0) }
                let passes = material?.passes ?? []
                return SceneInspectorItem(id: String(object.id ?? index), name: object.name ?? "Image \(index + 1)",
                                          kind: "Image", sourcePath: imagePath, materialPath: materialPath,
                                          texturePaths: passes.flatMap { $0.textures ?? [] },
                                          shaderPaths: passes.compactMap(\.shader), rawObject: rawObject,
                                          rawMaterial: materialPath.flatMap(rawJSON), rawParticle: nil)
            }
            if let particlePath = object.particle {
                let particle: WEParticleSystem? = data(particlePath).flatMap { try? JSONDecoder().decode(WEParticleSystem.self, from: $0) }
                let materialPath = particle?.material
                let material: WEMaterial? = materialPath.flatMap { data($0) }.flatMap { try? JSONDecoder().decode(WEMaterial.self, from: $0) }
                let passes = material?.passes ?? []
                return SceneInspectorItem(id: String(object.id ?? index), name: object.name ?? "Particle \(index + 1)",
                                          kind: "Particle", sourcePath: particlePath, materialPath: materialPath,
                                          texturePaths: passes.flatMap { $0.textures ?? [] },
                                          shaderPaths: passes.compactMap(\.shader), rawObject: rawObject,
                                          rawMaterial: materialPath.flatMap(rawJSON), rawParticle: rawJSON(particlePath))
            }
            return SceneInspectorItem(id: String(object.id ?? index), name: object.name ?? "Object \(index + 1)",
                                      kind: "Other", sourcePath: "", materialPath: nil, texturePaths: [], shaderPaths: [],
                                      rawObject: rawObject, rawMaterial: nil, rawParticle: nil)
        }
    }

    func loadTextures(for item: SceneInspectorItem) {
        textureLoadGeneration &+= 1
        let generation = textureLoadGeneration
        decodedTextures = []
        decodedItemID = nil
        guard !item.texturePaths.isEmpty else {
            loadingItemID = nil
            decodedItemID = item.id
            return
        }
        loadingItemID = item.id

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let textures = self.decodeTextures(for: item)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.textureLoadGeneration == generation else { return }
                self.decodedTextures = textures
                self.decodedItemID = item.id
                self.loadingItemID = nil
            }
        }
    }

    private func decodeTextures(for item: SceneInspectorItem) -> [SceneInspectorTexture] {
        let materialDirectory = ((item.materialPath ?? "") as NSString).deletingLastPathComponent
        let root = materialDirectory.split(separator: "/").first.map(String.init) ?? "materials"
        return item.texturePaths.compactMap { textureName in
            let fileName = (textureName as NSString).pathExtension.isEmpty ? "\(textureName).tex" : textureName
            let candidates = ["\(materialDirectory)/\(fileName)", "\(root)/\(fileName)", fileName]
                .filter { !$0.hasPrefix("/") }
            var visited = Set<String>()
            for path in candidates where visited.insert(path).inserted {
                guard let bytes = data(path) else { continue }
                let parser = TEXParser(data: bytes)
                let image = parser.extractAnimatedImages()?.images.first ?? parser.extractImage() ?? NSImage(data: bytes)
                if let image {
                    return SceneInspectorTexture(id: "\(item.id):\(path)", path: path, image: image)
                }
            }
            return nil
        }
    }

    private func data(_ path: String) -> Data? {
        package?.extractFile(named: path) ?? (try? Data(contentsOf: directory.appending(path: path)))
    }

    private func prettyJSON(_ json: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

struct SceneInspectorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SceneInspectorModel
    @State private var selectedID: String?

    init(wallpaper: WEWallpaper) {
        _model = StateObject(wrappedValue: SceneInspectorModel(wallpaper: wallpaper))
    }

    var body: some View {
        NavigationSplitView {
            List(model.items, selection: $selectedID) { item in
                Label(item.name, systemImage: item.kind == "Particle" ? "sparkles" : "photo")
                    .tag(item.id)
            }
            .navigationTitle("Scene Objects")
        } detail: {
            if let item = model.items.first(where: { $0.id == selectedID }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        LabeledContent("Type", value: item.kind)
                        if !item.sourcePath.isEmpty { LabeledContent("Source", value: item.sourcePath) }
                        if let material = item.materialPath { LabeledContent("Material", value: material) }
                        detailList("Textures", values: item.texturePaths)
                        decodedTextureList(for: item)
                        detailList("Shaders", values: item.shaderPaths)
                        sourceBlock("Object Properties", item.rawObject)
                        if let particle = item.rawParticle { sourceBlock("Particle System", particle) }
                        if let material = item.rawMaterial { sourceBlock("Material Properties", material) }
                    }
                    .padding()
                }
                .navigationTitle(item.name)
            } else if let error = model.errorMessage {
                ContentUnavailableView("Scene Unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ContentUnavailableView("Select a Scene Object", systemImage: "square.stack.3d.up")
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .help("Close Scene Inspector")
                    .keyboardShortcut(.cancelAction)
            }
        }
        .onAppear {
            selectedID = model.items.first?.id
        }
        .onChange(of: selectedID) { _, _ in loadSelectedTextures() }
    }

    @ViewBuilder private func decodedTextureList(for item: SceneInspectorItem) -> some View {
        if model.loadingItemID == item.id {
            ProgressView("Decoding textures...")
        } else if model.decodedItemID == item.id {
            ForEach(model.decodedTextures) { texture in
                VStack(alignment: .leading, spacing: 6) {
                    Text(texture.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Image(nsImage: texture.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 420)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            if !item.texturePaths.isEmpty && model.decodedTextures.isEmpty {
                ContentUnavailableView("Texture Unavailable", systemImage: "photo.badge.exclamationmark")
            }
        }
    }

    private func loadSelectedTextures() {
        guard let item = model.items.first(where: { $0.id == selectedID }) else { return }
        model.loadTextures(for: item)
    }

    @ViewBuilder private func detailList(_ title: String, values: [String]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                ForEach(values, id: \.self) { Text($0).font(.caption.monospaced()) }
            }
        }
    }

    private func sourceBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(8).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}