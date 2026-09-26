//
//  WallpaperPreview.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import SwiftUI

struct WallpaperPreview: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    
    @Environment(\.undoManager) var undoManager
    
    @State var isEditingId = ""
    @State var title = ""
    @State var newTag = ""
    
    @State var hoveredTag: String?
    /// SwiftUI cannot observe UserDefaults, so this store is what re-renders the music controls
    /// after their bindings write.
    @ObservedObject private var musicSync = VideoMusicSyncStore.shared
    @ObservedObject private var favorites = FavoritesStore.shared
    @State var isTagsHovered = false

    init(contentViewModel viewModel: ContentViewModel, wallpaperViewModel: WallpaperViewModel) {
        self.viewModel = viewModel
        self.wallpaperViewModel = wallpaperViewModel
    }
    
    var wallpaperSize: String {
        guard let sizeBytes = try? wallpaperViewModel.displayedWallpaper.wallpaperDirectory.directoryTotalAllocatedSize(includingSubfolders: true)
        else {
            return "??? MB"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Pinned outside the ScrollView so scrolled content cannot ride up under the titlebar.
            Text("Details")
                .font(.title3.bold())
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 12)
                .padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 10) {
                        GifImage(contentsOf: { (url: URL) in
                            if let selectedProject = try? JSONDecoder()
                                .decode(WEProject.self, from: Data(contentsOf: url.appending(path: "project.json"))) {
                                return url.appending(path: selectedProject.preview)
                            }
                            return Bundle.main.url(forResource: "WallpaperNotFound", withExtension: "mp4")!
                        }(wallpaperViewModel.displayedWallpaper.wallpaperDirectory), animates: viewModel.isApplicationActive)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .background(Color(nsColor: NSColor.controlBackgroundColor))
                            .frame(width: 280, height: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 16.0))
                            .border(Color.white, width: 4)
                        HStack {
                            if isEditingId == "title" {
                                TextField("Wallpaper Title", text: $title)
                                    .onSubmit {
                                        var wallpaper = wallpaperViewModel.displayedWallpaper
                                        
                                        wallpaper.project.title = title
                                        
                                        guard let data = try? JSONEncoder().encode(wallpaper.project) else { return }
                                        
                                        try? data.write(to: wallpaper.wallpaperDirectory.appending(path: "project.json"), options: .atomic)
                                        
                                        wallpaperViewModel.inspect(wallpaper)
                                        
                                        isEditingId = ""
                                    }
                            } else {
                                Text(wallpaperViewModel.displayedWallpaper.project.title.isEmpty ? "Untitled" : wallpaperViewModel.displayedWallpaper.project.title)
                                    .frame(minWidth: 50)
                                    .id("title")
                                    .lineLimit(1)
                                    .onTapGesture(count: 2) {
                                        title = wallpaperViewModel.displayedWallpaper.project.title
                                        isEditingId = "title"
                                    }
                                Image(systemName: "square.and.pencil")
                            }
                            
                        }
                    }
                        HStack {
                            Spacer()
                        AsyncImage(url: wallpaperViewModel.inspectedAuthor?.avatarURL) { phase in
                            if case let .success(image) = phase {
                                image.resizable()
                            } else {
                                Image("we.placeholder").resizable()
                            }
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                        let authorID = wallpaperViewModel.inspectedAuthor?.steamId ?? wallpaperViewModel.inspectedWorkshopItem?.creatorId
                        if let authorID {
                            Button {
                                viewModel.topTabBarSelection = 1
                                viewModel.workshopVM.showAuthor(authorID)
                            } label: {
                                Text(wallpaperViewModel.inspectedAuthor?.personaName ?? authorID)
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                            .buttonStyle(.link)
                            .help("View this author's Workshop items")
                        } else {
                            Text("Unknown Author")
                        }
                        Spacer()
                    }
                    favoriteControl
                    HStack {
                        Text(wallpaperViewModel.displayedWallpaper.project.type)
                        Text(wallpaperSize)
                    }
                    .font(.footnote)
                    
                    ViewThatFits(in: .horizontal) {
                        tags.animation(.spring(), value: isTagsHovered)
                        ScrollView(.horizontal, showsIndicators: false) {
                            tags.animation(.spring(), value: isTagsHovered)
                        }
                    }
                    
                    .onHover { isTagsHovered = $0 }
                    
                    if isEditingId == "tags" {
                        HStack {
                            Button {
                                newTag = ""
                                isEditingId = ""
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                            TextField("New Tag", text: $newTag)
                                .onSubmit {
                                    defer {
                                        newTag = ""
                                        isEditingId = ""
                                    }
                                    
                                    guard !newTag.isEmpty else { return }
                                    
                                    var wallpaper = wallpaperViewModel.displayedWallpaper
                                    
                                    var tags = wallpaper.project.tags ?? []
                                    
                                    tags = Array(Set(tags)) // remove duplicate items
                                    
                                    tags.append(newTag)
                                    
                                    tags = Array(Set(tags)) // remove duplicate items
                                    
                                    wallpaper.project.tags = tags.sorted()
                                    
                                    guard let data = try? JSONEncoder().encode(wallpaper.project) else { return }
                                    
                                    try? data.write(to: wallpaper.wallpaperDirectory.appending(path: "project.json"), options: .atomic)
                                    
                                    wallpaperViewModel.inspect(wallpaper)
                                }
                        }
                    }
                    VStack(spacing: 3) {
                        HStack(spacing: 3) {
                            Button {
                                wallpaperViewModel.applyInspectedWallpaper()
                            } label: {
                                Label("Set Wallpaper", systemImage: "checkmark.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Button(role: .destructive) {
                                viewModel.hoveredWallpaper = wallpaperViewModel.displayedWallpaper
                                viewModel.isUnsubscribeConfirming = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .help("Delete wallpaper")
                        }
                        Button {
                            AppDelegate.shared.showSceneInspector(for: wallpaperViewModel.displayedWallpaper,
                                                                  scopes: wallpaperViewModel.editedPropertyScopes(of: wallpaperViewModel.displayedWallpaper))
                        } label: {
                            Label("Scene Inspector", systemImage: "square.stack.3d.up")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    // MARK: Properties
                    CollapsibleSection(title: "Properties") {
                        VStack(alignment: .leading, spacing: 16) {
                            if wallpaperViewModel.displayedWallpaper.project.workshopid == nil {
                                Picker("Age Rating", selection: Binding(
                                    get: { wallpaperViewModel.displayedWallpaper.project.contentrating ?? "Everyone" },
                                    set: { wallpaperViewModel.setContentRating($0, for: wallpaperViewModel.displayedWallpaper) }
                                )) {
                                    Text("Everyone").tag("Everyone")
                                    Text("Questionable").tag("Questionable")
                                    Text("Mature").tag("Mature")
                                }
                                .pickerStyle(.menu)
                            }
                            HStack {
                                Label("Placement", systemImage: "arrow.up.left.and.arrow.down.right")
                                infoButton(SceneHelp.placement)
                                Spacer()
                                Picker("", selection: $wallpaperViewModel.wallpaperPlacement) {
                                    ForEach(WallpaperPlacement.allCases) { placement in
                                        Text(placement.rawValue).tag(placement)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 120)
                            }
                            switch wallpaperViewModel.displayedWallpaper.project.type.lowercased() {
                            case "video", "remote-video":
                                HStack {
                                    Label("Volume", systemImage: "speaker.wave.3.fill")
                                    infoButton(SceneHelp.volume)
                                    Spacer()
                                    NumericSliderInput(value: $wallpaperViewModel.playVolume, range: 0...1,
                                                       defaultValue: 1, displayScale: 100, suffix: "%",
                                                       fractionDigits: 0, sliderWidth: 100, fieldWidth: 36)
                                }
                                HStack {
                                    Label("Video Speed", systemImage: "play.fill")
                                    infoButton(SceneHelp.videoSpeed)
                                    Spacer()
                                    NumericSliderInput(value: $wallpaperViewModel.playRate, range: 0...2,
                                                       defaultValue: 1, step: 0.1, suffix: "x",
                                                       fractionDigits: 2, sliderWidth: 100, fieldWidth: 42)
                                }
                                HStack {
                                    Label("Audio Speed", systemImage: "waveform")
                                    infoButton(SceneHelp.audioSpeed)
                                    Spacer()
                                    Button {
                                        wallpaperViewModel.arePlaybackRatesLinked.toggle()
                                    } label: {
                                        Image(systemName: "link")
                                            .foregroundStyle(wallpaperViewModel.arePlaybackRatesLinked ? Color.primary : .gray)
                                    }
                                    .buttonStyle(.plain)
                                    .help(SceneHelp.linkRates)
                                    NumericSliderInput(value: $wallpaperViewModel.audioPlayRate, range: 0...2,
                                                       defaultValue: 1, step: 0.1, suffix: "x",
                                                       fractionDigits: 2, sliderWidth: 76, fieldWidth: 42)
                                        .disabled(wallpaperViewModel.arePlaybackRatesLinked)
                                }
                            case "scene":
                                MissingWorkshopDependenciesBanner(steamCmd: viewModel.steamCmd, wallpaper: wallpaperViewModel.displayedWallpaper)
                                    .id(wallpaperViewModel.displayedWallpaper.wallpaperDirectory)
                                if wallpaperHasSceneAudio(wallpaperViewModel.displayedWallpaper) {
                                    sceneMusicControls(for: wallpaperViewModel.displayedWallpaper)
                                }
                            default:
                                EmptyView()
                            }
                        }
                    }
                    SceneUserPropertiesView(wallpaper: wallpaperViewModel.displayedWallpaper,
                                            scopes: wallpaperViewModel.editedPropertyScopes(of: wallpaperViewModel.displayedWallpaper))
                        .id([wallpaperViewModel.displayedWallpaper.wallpaperDirectory.path]
                            + wallpaperViewModel.editedPropertyScopes(of: wallpaperViewModel.displayedWallpaper).map(\.description))
                    VStack(spacing: 3) {
                        HStack(spacing: 3) {
                            Text("Your Presets")
                            VStack {
                                Divider()
                                    .frame(height: 1)
                                    .overlay(Color.accentColor)
                            }
                        }
                        Group {
                            HStack(spacing: 3) {
                                Button { } label: {
                                    Label("Load", systemImage: "folder.fill")
                                        .frame(maxWidth: .infinity)
                                    
                                }
                                Button { } label: {
                                    Label("Save", systemImage: "square.and.arrow.down.fill")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            Button { } label: {
                                Label("Apply to all Wallpapers", systemImage: "list.bullet.rectangle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            Button { } label: {
                                Label("Share JSON", systemImage: "arrow.2.squarepath")
                                    .frame(maxWidth: .infinity)
                            }
                            Button { } label: {
                                Label("Reset", systemImage: "arrow.triangle.2.circlepath")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        }
                        .disabled(true)
                    }
                }
                .blur(radius: wallpaperViewModel.displayedWallpaper.project == .invalid ? 16.0 : 0)
                .overlay {
                    if wallpaperViewModel.displayedWallpaper.project == .invalid {
                        Text("Please select a valid wallpaper")
                    }
                }
                .disabled(wallpaperViewModel.displayedWallpaper.project == .invalid ? true : false)
                .animation(.default, value: wallpaperViewModel.displayedWallpaper.project)
                .padding([.horizontal, .top])
            }

            HStack {
                Spacer()
                Button {
                    AppDelegate.shared.mainWindowController.close()
                } label: {
                    Text("OK").frame(width: 50)
                }
                .buttonStyle(.borderedProminent)
                Button { 
                    AppDelegate.shared.mainWindowController.close()
                } label: {
                    Text("Cancel").frame(width: 50)
                }
            }
            .padding()
        }
    }

    private static var sceneAudioPresenceCache: [String: Bool] = [:]

    private func wallpaperHasSceneAudio(_ wallpaper: WEWallpaper) -> Bool {
        let key = wallpaper.wallpaperDirectory.path
        if let cached = Self.sceneAudioPresenceCache[key] { return cached }
        let extensions: Set<String> = ["mp3", "ogg", "wav", "m4a", "flac"]
        let fm = FileManager.default
        var found = false
        if let enumerator = fm.enumerator(at: wallpaper.wallpaperDirectory, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                if extensions.contains(url.pathExtension.lowercased()) {
                    found = true
                    break
                }
                if url.pathExtension.lowercased() == "pkg",
                   let data = try? Data(contentsOf: url),
                   let parser = try? PKGParser(data: data),
                   parser.fileList.contains(where: { extensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }) {
                    found = true
                    break
                }
            }
        }
        Self.sceneAudioPresenceCache[key] = found
        return found
    }

    private var favoriteControl: some View {
        let wallpaper = wallpaperViewModel.displayedWallpaper
        let isFavorite = favorites.contains(wallpaper)
        let subscriptions = wallpaperViewModel.inspectedWorkshopItem?.subscriptions ?? 0
        return Button {
            favorites.toggle(wallpaper)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(isFavorite ? Color.red : Color.secondary)
                if subscriptions > 0 {
                    Text(formatCount(subscriptions))
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
    }

    private func sceneMusicControls(for wallpaper: WEWallpaper) -> some View {
        let enabledKey = "SceneMusicEnabled.\(wallpaper.wallpaperDirectory.path)"
        let volumeKey = "SceneMusicVolume.\(wallpaper.wallpaperDirectory.path)"
        let enabled = Binding<Bool>(
            get: { UserDefaults.standard.object(forKey: enabledKey) == nil ? true : UserDefaults.standard.bool(forKey: enabledKey) },
            set: {
                UserDefaults.standard.set($0, forKey: enabledKey)
                musicSync.objectWillChange.send()
                NotificationCenter.default.post(name: .sceneMusicSettingsDidChange, object: nil,
                                                userInfo: ["path": wallpaper.wallpaperDirectory.path])
            }
        )
        let volume = Binding<Double>(
            get: { UserDefaults.standard.object(forKey: volumeKey) == nil ? 1 : UserDefaults.standard.double(forKey: volumeKey) },
            set: {
                UserDefaults.standard.set($0, forKey: volumeKey)
                musicSync.objectWillChange.send()
                NotificationCenter.default.post(name: .sceneMusicSettingsDidChange, object: nil,
                                                userInfo: ["path": wallpaper.wallpaperDirectory.path])
            }
        )
        return VStack(alignment: .leading, spacing: 8) {
            Toggle("Scene Music", isOn: enabled)
                .toggleStyle(.checkbox)
                .help(SceneHelp.sceneMusic)
            if enabled.wrappedValue {
                HStack {
                    Label("Scene Music Volume", systemImage: "music.note")
                    infoButton(SceneHelp.sceneMusicVolume)
                    Spacer()
                    NumericSliderInput(value: volume, range: 0...1,
                                       defaultValue: 1, displayScale: 100, suffix: "%",
                                       fractionDigits: 0, sliderWidth: 100, fieldWidth: 36)
                }
            }
        }
    }
    
    /// Shows all tags about current wallpaper in horizontal
    var tags: some View {
        HStack {
            if let tags = wallpaperViewModel.displayedWallpaper.project.tags {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .padding(5)
                        .background {
                            RoundedRectangle(cornerRadius: 25.0)
                                .colorInvert()
                                .foregroundStyle(Color.primary)
                            RoundedRectangle(cornerRadius: 25.0)
                                .stroke(Color.secondary, lineWidth: 1.6)
                        }
                        .overlay(alignment: .topTrailing) {
                            if hoveredTag == tag {
                                Button {
                                    var wallpaper = wallpaperViewModel.displayedWallpaper
                                    
                                    guard var tags = wallpaper.project.tags else { return } // else case seems impossible, however much safer
                                    
                                    tags = Array(Set(tags)) // remove duplicate items
                                    
                                    guard let index = tags.firstIndex(where: { $0 == tag }) else { return }
                                    
                                    tags.remove(at: index)
                                    
                                    wallpaper.project.tags = tags
                                    
                                    guard let data = try? JSONEncoder().encode(wallpaper.project) else { return }
                                    
                                    try? data.write(to: wallpaper.wallpaperDirectory.appending(path: "project.json"), options: .atomic)
                                    
                                    wallpaperViewModel.inspect(wallpaper)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.white, .red)
                                .symbolRenderingMode(.palette)
                                .offset(x: 5, y: -2.5)
                            }
                        }
                        .onHover { hovered in
                            if hovered {
                                hoveredTag = tag
                            } else {
                                hoveredTag = nil
                            }
                        }
                }
            } else {
                Text("No Tags")
                    .foregroundStyle(Color.secondary)
            }
            
            if isTagsHovered {
                Button {
                    isEditingId = "tags"
                } label: {
                    Image(systemName: "plus")
                        .font(.body)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.footnote)
        .lineLimit(1)
    }

    private func formatCount(_ count: Int) -> String {
        count >= 1_000 ? String(format: "%.1fK", Double(count) / 1_000) : "\(count)"
    }

    private func infoButton(_ help: String) -> some View {
        InfoTip(help)
    }
}

/// Shows when a scene wallpaper references effects/materials that live in another Steam Workshop
/// item that isn't installed locally, and lets the user download + link them in.
private struct MissingWorkshopDependenciesBanner: View {
    @ObservedObject var steamCmd: SteamCmdService
    let wallpaper: WEWallpaper

    @State private var missingIds: [String] = []

    var body: some View {
        Group {
            if !missingIds.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("This wallpaper needs \(missingIds.count) other Workshop item\(missingIds.count == 1 ? "" : "s") to render correctly.",
                          systemImage: "shippingbox")
                        .font(.footnote)
                    ForEach(missingIds, id: \.self) { workshopId in
                        HStack {
                            Text(workshopId).font(.footnote).foregroundStyle(.secondary)
                            Spacer()
                            statusView(for: workshopId)
                        }
                    }
                    if !steamCmd.isInstalled || !steamCmd.isLoggedIn {
                        Text("Log in on the Workshop tab to download these.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Download All") {
                            for workshopId in missingIds {
                                steamCmd.downloadWorkshopItem(workshopId: workshopId, asDependency: true)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }
        }
        .onAppear { refresh() }
        .onChange(of: steamCmd.downloadProgress) { _ in
            for workshopId in missingIds where steamCmd.downloadProgress[workshopId] == .completed {
                WorkshopDependencyResolver.linkInstalledDependencies(for: wallpaper)
            }
            refresh()
        }
    }

    @ViewBuilder
    private func statusView(for workshopId: String) -> some View {
        switch steamCmd.downloadProgress[workshopId] {
        case .downloading(let status):
            Text(status).font(.caption).foregroundStyle(.secondary)
        case .completed:
            Label("Linked", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        case nil:
            EmptyView()
        }
    }

    private func refresh() {
        missingIds = Array(WorkshopDependencyResolver.missingWorkshopIds(for: wallpaper)).sorted()
    }
}

extension URL {
    /// check if the URL is a directory and if it is reachable
    func isDirectoryAndReachable() throws -> Bool {
        guard try resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            return false
        }
        return try checkResourceIsReachable()
    }

    /// returns total allocated size of a the directory including its subFolders or not
    func directoryTotalAllocatedSize(includingSubfolders: Bool = false) throws -> Int? {
        guard try isDirectoryAndReachable() else { return nil }
        if includingSubfolders {
            guard
                let urls = FileManager.default.enumerator(at: self, includingPropertiesForKeys: nil)?.allObjects as? [URL] else { return nil }
            return try urls.lazy.reduce(0) {
                    (try $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0) + $0
            }
        }
        return try FileManager.default.contentsOfDirectory(at: self, includingPropertiesForKeys: nil).lazy.reduce(0) {
                 (try $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                    .totalFileAllocatedSize ?? 0) + $0
        }
    }
}
