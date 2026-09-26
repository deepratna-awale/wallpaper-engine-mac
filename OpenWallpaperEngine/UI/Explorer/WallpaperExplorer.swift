//
//  WallpaperExplorer.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import SwiftUI

struct WallpaperExplorer: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @State private var isCreatePlaylistPresented = false
    @State private var footerHeight: CGFloat = 44

    init(contentViewModel viewModel: ContentViewModel, wallpaperViewModel: WallpaperViewModel) {
        self.viewModel = viewModel
        self.wallpaperViewModel = wallpaperViewModel
    }

    private func recomputePageSize(in geometry: GeometryProxy) {
        viewModel.updateInstalledItemsPerPage(for: CGSize(
            width: geometry.size.width,
            height: max(geometry.size.height - footerHeight - 8, 1)
        ))
    }
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 8) {
                if viewModel.displayedWallpapers.isEmpty {
                    Spacer()
                    Text("No wallpapers found for your search.")
                        .font(.title)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                } else {
                    LazyVGrid(columns: [
                        GridItem(
                            .adaptive(
                                minimum: viewModel.explorerIconSize,
                                maximum: viewModel.explorerIconSize
                            ),
                            spacing: 8
                        )
                    ], alignment: .leading, spacing: 8) {
                        ForEach(Array(viewModel.displayedWallpapers.enumerated()), id: \.0) { (index, wallpaper) in
                            ExplorerItem(viewModel: viewModel, wallpaperViewModel: wallpaperViewModel, wallpaper: wallpaper, index: index)
                                .contextMenu {
                                    ExplorerItemMenu(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel, current: wallpaper)
                                    ExplorerGlobalMenu(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel)
                                }
                                .animation(.spring(), value: viewModel.imageScaleIndex)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                VStack(spacing: 8) {
                    InstalledPagination(viewModel: viewModel)
                        .padding(.vertical, 8)
                    Button {
                        isCreatePlaylistPresented = true
                    } label: {
                        Label("Create Playlist", systemImage: "rectangle.stack.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.selectedWallpapers.isEmpty)
                }
                .background(GeometryReader { footer in
                    Color.clear.preference(key: ExplorerFooterHeightKey.self, value: footer.size.height)
                })
            }
            .onPreferenceChange(ExplorerFooterHeightKey.self) { height in
                footerHeight = height
            }
            .onAppear { recomputePageSize(in: geometry) }
            .onChange(of: geometry.size) { recomputePageSize(in: geometry) }
            // Tile size changes the row/column count, so the page size has to be recomputed too;
            // otherwise the grid overflows and pushes the footer controls out of view.
            .onChange(of: viewModel.explorerIconSize) { recomputePageSize(in: geometry) }
            .onChange(of: footerHeight) { recomputePageSize(in: geometry) }
            .sheet(isPresented: $isCreatePlaylistPresented) {
                CreatePlaylistSheet(
                    wallpapers: viewModel.selectedWallpaperItems(),
                    wallpaperViewModel: wallpaperViewModel,
                    onComplete: {
                        viewModel.clearSelection()
                        isCreatePlaylistPresented = false
                    }
                )
                .frame(width: 480, height: 360)
            }
        }
    }
}

private struct ExplorerFooterHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 44
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct CreatePlaylistSheet: View {
    let wallpapers: [WEWallpaper]
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    let onComplete: () -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Playlist").font(.title2.bold())
            TextField("Playlist name", text: $name)
                .textFieldStyle(.roundedBorder)
            Text("\(wallpapers.count) wallpapers will be added")
                .foregroundStyle(.secondary)
            List(wallpapers) { wallpaper in
                Text(wallpaper.project.title.isEmpty ? "Untitled" : wallpaper.project.title)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onComplete)
                Button("Save") {
                    guard wallpaperViewModel.createPlaylist(named: name, wallpapers: wallpapers) else { return }
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

private struct InstalledPagination: View {
    @ObservedObject var viewModel: ContentViewModel

    var body: some View {
        HStack(spacing: 6) {
            Button {
                viewModel.currentPage -= 1
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(viewModel.currentPage == 1)

            ForEach(pageNumbers, id: \.self) { page in
                if page == viewModel.currentPage {
                    pageButton(page)
                        .buttonStyle(.borderedProminent)
                } else {
                    pageButton(page)
                        .buttonStyle(.bordered)
                }
            }

            Button {
                viewModel.currentPage += 1
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!viewModel.hasNextWallpaperPage)
        }
    }

    private var pageNumbers: [Int] {
        let firstPage = max(1, viewModel.currentPage - 2)
        let lastPage = min(viewModel.maxPage, viewModel.currentPage + 2)
        return Array(firstPage...lastPage)
    }

    private func pageButton(_ page: Int) -> some View {
        Button("\(page)") {
            viewModel.currentPage = page
        }
    }
}

struct PlaylistView: View {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @State private var playlistName = ""

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Playlists").font(.title2.bold())
                    Spacer()
                    Button { playlistName = "" } label: { Image(systemName: "plus") }
                        .help("Create playlist")
                }
                HStack {
                    TextField("New playlist", text: $playlistName)
                    Button {
                        wallpaperViewModel.createPlaylist(named: playlistName)
                        playlistName = ""
                    } label: { Image(systemName: "plus.circle.fill") }
                    .disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                List(wallpaperViewModel.playlists) { playlist in
                    Button {
                        wallpaperViewModel.activePlaylistID = playlist.id
                    } label: {
                        HStack {
                            Label(playlist.name, systemImage: playlist.id == wallpaperViewModel.activePlaylistID ? "checkmark" : "rectangle.stack")
                            Spacer()
                            Text("\(playlist.items.count)").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .frame(width: 260)
            Divider()
            playlistDetail
        }
    }

    @ViewBuilder private var playlistDetail: some View {
        if let playlist = wallpaperViewModel.activePlaylist {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(playlist.name).font(.largeTitle.bold())
                        Spacer()
                        Button(role: .destructive) {
                            wallpaperViewModel.deletePlaylist(playlist)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Delete playlist")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Rotate automatically", isOn: $wallpaperViewModel.playlistEnabled)
                        Toggle("Shuffle", isOn: $wallpaperViewModel.playlistShuffle)
                        Toggle("Repeat", isOn: $wallpaperViewModel.playlistRepeats)
                        Toggle("Change when video ends", isOn: Binding(
                            get: { playlist.changeWhenVideoEnds },
                            set: { wallpaperViewModel.setPlaylistChangeWhenVideoEnds($0) }
                        ))
                        HStack {
                            Text("Wallpaper duration")
                            Slider(value: Binding(
                                get: { playlist.duration },
                                set: { wallpaperViewModel.setPlaylistDuration($0) }
                            ), in: 5...3600)
                            Text("\(Int(playlist.duration))s")
                                .font(.caption.monospacedDigit())
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                    HStack {
                        Button { wallpaperViewModel.previousPlaylistWallpaper() } label: { Label("Previous", systemImage: "backward.fill") }
                        Button { wallpaperViewModel.nextPlaylistWallpaper() } label: { Label("Next", systemImage: "forward.fill") }
                        Text("\(playlist.items.count) wallpapers").foregroundStyle(.secondary)
                    }
                    ForEach(playlist.items) { item in
                        HStack(spacing: 10) {
                            GifImage(contentsOf: previewURL(for: item.wallpaper), animates: false)
                                .resizable()
                                .aspectRatio(1, contentMode: .fill)
                                .frame(width: 64, height: 64)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(item.wallpaper.project.title.isEmpty ? "Untitled" : item.wallpaper.project.title)
                                .lineLimit(1)
                                .frame(width: 180, alignment: .leading)
                            Button { wallpaperViewModel.movePlaylistItem(itemID: item.id, offset: -1) } label: { Image(systemName: "chevron.up") }
                                .disabled(playlist.items.first?.id == item.id)
                            Button { wallpaperViewModel.movePlaylistItem(itemID: item.id, offset: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(playlist.items.last?.id == item.id)
                            Button(role: .destructive) { wallpaperViewModel.removeFromPlaylist(itemID: item.id) } label: { Image(systemName: "minus.circle") }
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                .padding(24)
            }
        } else {
            ContentUnavailableView("Create a Playlist", systemImage: "rectangle.stack.badge.plus",
                                   description: Text("Create a playlist to manage wallpaper rotation."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func previewURL(for wallpaper: WEWallpaper) -> URL {
        if wallpaper.project.type.lowercased() == "remote-video",
           let url = URL(string: wallpaper.project.file) {
            return url
        }
        if wallpaper.project.type.lowercased() == "remote-image",
           let url = URL(string: wallpaper.project.file) {
            return url
        }
        return wallpaper.wallpaperDirectory.appending(path: wallpaper.project.preview)
    }
}

// MARK: - View Modifiers Extension
struct SelectedItem: ViewModifier {
    var selected: Bool
    
    init(_ selected: Bool) {
        self.selected = selected
    }
    
    func body(content: Content) -> some View {
        return content
            .border(Color.accentColor, width: selected ? 3 : 0)
    }
}

extension View {
    func selected(_ selected: Bool = true) -> some View {
        return modifier(SelectedItem(selected))
    }
}
