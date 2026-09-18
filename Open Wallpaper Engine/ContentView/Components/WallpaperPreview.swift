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
    @State var isTagsHovered = false
    @State var isSceneInspectorPresented = false
    
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
        VStack {
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
                    if let subscriptions = wallpaperViewModel.inspectedWorkshopItem?.subscriptions,
                       subscriptions > 0 {
                        Label("\(formatCount(subscriptions))", systemImage: "heart")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        if let item = wallpaperViewModel.inspectedWorkshopItem {
                            Label("\(item.votesUp)", systemImage: "hand.thumbsup")
                                .foregroundStyle(.green)
                            Label("\(item.votesDown)", systemImage: "hand.thumbsdown")
                                .foregroundStyle(.red)
                        } else {
                            Text("Rating unavailable")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
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
                        HStack(spacing: 3) {
                            Button { } label: {
                                Label("Comment", systemImage: "text.badge.star")
                                    .frame(maxWidth: .infinity)
                            }
                            Button { } label: {
                                Image(systemName: "doc.on.doc.fill")
                            }
                            Button { } label: {
                                Image(systemName: "exclamationmark.triangle.fill")
                            }
                        }
                        .disabled(true)
                    }
                    // MARK: Properties
                    HStack(spacing: 3) {
                        Text("Properties")
                        VStack {
                            Divider()
                                .frame(height: 1)
                                .overlay(Color.accentColor)
                        }
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Menu {
                                ForEach(WallpaperPlacement.allCases) { placement in
                                    Button(placement.rawValue) {
                                        wallpaperViewModel.wallpaperPlacement = placement
                                    }
                                }
                            } label: {
                                Label(
                                    "Placement: \(wallpaperViewModel.wallpaperPlacement.rawValue)",
                                    systemImage: "arrow.up.left.and.arrow.down.right"
                                )
                            }
                            .menuStyle(.borderedButton)
                        }
                        ColorPicker(selection: .constant(.red), supportsOpacity: true) {
                            HStack {
                                Label("Scheme Color", systemImage: "paintpalette.fill")
                                Spacer()
                            }
                        }
                        .opacity(0.5)
                        .disabled(true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        switch wallpaperViewModel.displayedWallpaper.project.type.lowercased() {
                        case "video":
                            HStack {
                                Label("Volume", systemImage: "speaker.wave.3.fill")
                                Spacer()
                                Slider(value: $wallpaperViewModel.playVolume, in: 0...1).frame(width: 100)
                                Text(String(format: "%.0f", wallpaperViewModel.playVolume * 100) + "%")
                                    .frame(width: 35)
                            }
                            HStack {
                                Label("Video Speed", systemImage: "play.fill")
                                Spacer()
                                Slider(value: $wallpaperViewModel.playRate, in: 0...2, step: 0.1).frame(width: 100)
                                Text(String(format: "%.01fx", wallpaperViewModel.playRate))
                                    .frame(width: 35)
                            }
                            HStack {
                                Label("Audio Speed", systemImage: "waveform")
                                Spacer()
                                Button {
                                    wallpaperViewModel.arePlaybackRatesLinked.toggle()
                                } label: {
                                    Image(systemName: "link")
                                        .foregroundStyle(wallpaperViewModel.arePlaybackRatesLinked ? Color.primary : .gray)
                                }
                                .buttonStyle(.plain)
                                .help(wallpaperViewModel.arePlaybackRatesLinked ? "Unlink audio speed" : "Link audio speed")
                                Slider(value: $wallpaperViewModel.audioPlayRate, in: 0...2, step: 0.1)
                                    .frame(width: 76)
                                    .disabled(wallpaperViewModel.arePlaybackRatesLinked)
                                Text(String(format: "%.01fx", wallpaperViewModel.audioPlayRate))
                                    .frame(width: 35)
                            }
                        case "web":
                            EmptyView()
                        case "scene":
                            Button {
                                isSceneInspectorPresented = true
                            } label: {
                                Label("Scene Inspector", systemImage: "square.stack.3d.up")
                                    .frame(maxWidth: .infinity)
                            }
                            SceneUserPropertiesView(wallpaper: wallpaperViewModel.displayedWallpaper)
                                .id(wallpaperViewModel.displayedWallpaper.wallpaperDirectory)
                        default:
                            EmptyView()
                        }
                    }
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
        .sheet(isPresented: $isSceneInspectorPresented) {
            SceneInspectorView(wallpaper: wallpaperViewModel.displayedWallpaper)
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
