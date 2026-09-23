//
//  ExplorerItemMenu.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/29.
//

import SwiftUI

struct ExplorerItemMenu: SubviewOfContentView {
    
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @ObservedObject private var favorites = FavoritesStore.shared

    var hoveredWallpaper: WEWallpaper
    
    init(contentViewModel viewModel: ContentViewModel, wallpaperViewModel: WallpaperViewModel, current hoveredWallpaper: WEWallpaper) {
        self.wallpaperViewModel = wallpaperViewModel
        self.viewModel = viewModel
        self.hoveredWallpaper = hoveredWallpaper
    }
    
    var body: some View {
        Group {
            Section {
                Menu("Add to Playlist") {
                    if wallpaperViewModel.playlists.isEmpty {
                        Text("Create a playlist first")
                    } else {
                        ForEach(wallpaperViewModel.playlists) { playlist in
                            Button {
                                let selected = viewModel.selectedWallpaperItems()
                                let wallpapers = selected.isEmpty ? [hoveredWallpaper] : selected
                                wallpaperViewModel.addToPlaylist(wallpapers, playlistID: playlist.id)
                            } label: {
                                Label(playlist.name, systemImage: playlist.id == wallpaperViewModel.activePlaylistID ? "checkmark" : "rectangle.stack")
                            }
                        }
                    }
                }
                Button {
                    viewModel.hoveredWallpaper = hoveredWallpaper
                    viewModel.isUnsubscribeConfirming = true
                } label: {
                    Label("Unsubscribe", systemImage: "xmark")
                }
                if viewModel.selectedWallpapers.count > 1 {
                    Button(role: .destructive) {
                        viewModel.isBatchUnsubscribeConfirming = true
                    } label: {
                        Label("Unsubscribe Selected (\(viewModel.selectedWallpapers.count))", systemImage: "xmark.circle")
                    }
                }
                Button {
                    favorites.toggle(hoveredWallpaper)
                } label: {
                    Label(favorites.contains(hoveredWallpaper) ? "Remove from Favorites" : "Add to Favorites",
                          systemImage: favorites.contains(hoveredWallpaper) ? "heart.slash" : "heart.fill")
                }
            }
            
            Section {
                Button {
                    
                } label: {
                    Label("Open in Workshop", systemImage: "cloud.fill")
                }.disabled(true)
                Menu("Related Wallpapers") {
                    Link(destination: URL(string: "https://github.com/haren724/open-wallpaper-engine-mac")!) {
                        Label("Browse All By", systemImage: "person.fill")
                    }
                    Link(destination: URL(string: "https://github.com/haren724/open-wallpaper-engine-mac")!) {
                        Label("Browse Presets", systemImage: "cloud.fill")
                    }
                }.disabled(true)
                Menu("Report & Block") {
                    Button(role: .destructive) {
                        
                    } label: {
                        Label("Report", systemImage: "exclamationmark.triangle.fill")
                    }
                    Button {
                        
                    } label: {
                        Label("Manage Blocklist", systemImage: "hand.raised.fill")
                    }
                }.disabled(true)
            }
            
            Section {
                Button {
                    
                } label: {
                    Label("Assign Hotkey", systemImage: "command.square")
                }.disabled(true)
                Button {
                    NSWorkspace.shared.selectFile(nil,
                                                  inFileViewerRootedAtPath: hoveredWallpaper.wallpaperDirectory.path(percentEncoded: false))
                } label: {
                    Label("Open in Finder", systemImage: "folder.badge.gearshape")
                }
            }
        }
        .labelStyle(.titleAndIcon)
    }
}
