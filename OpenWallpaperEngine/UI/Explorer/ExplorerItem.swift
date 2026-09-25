//
//  ExplorerItem.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/25.
//

import SwiftUI

struct ExplorerItem: SubviewOfContentView {
    
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @ObservedObject var safeRestart = AppDelegate.shared.safeRestart
    
    @AppStorage("TestAnimates") var animates = false
    
    var wallpaper: WEWallpaper
    var index: Int
    
    var body: some View {
        ZStack(alignment: .bottom) {
            GifImage(contentsOf: { (url: URL) in
                if let selectedProject = try? JSONDecoder()
                    .decode(WEProject.self, from: Data(contentsOf: url.appending(path: "project.json"))) {
                    return url.appending(path: selectedProject.preview)
                }
                return Bundle.main.url(forResource: "WallpaperNotFound", withExtension: "mp4")!
            }(wallpaper.wallpaperDirectory), animates: animates && viewModel.isApplicationActive)
            .resizable()
            .scaleEffect((viewModel.imageScaleIndex == index ? 1.2 : 1.0) * 1.08)
            .aspectRatio(1.0, contentMode: .fill)
            .clipped()
            
            Text(wallpaper.project.title)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 30)
                .padding(4)
                .background(Color(white: 0, opacity: viewModel.imageScaleIndex == index ? 0.4 : 0.2))
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color(white: viewModel.imageScaleIndex == index ? 0.9 : 0.7))
            
//            Spacer()
//                .onHover { onHover in
//                    if onHover {
//                        viewModel.imageScaleIndex = index
//                    } else {
//                        viewModel.imageScaleIndex = -1
//                    }
//                }
        }
        .selected(wallpaper.wallpaperDirectory == wallpaperViewModel.displayedWallpaper.wallpaperDirectory)
        .overlay(
            RoundedRectangle(cornerRadius: 2)
            .stroke(Color.blue, lineWidth: wallpaper.wallpaperDirectory == wallpaperViewModel.displayedWallpaper.wallpaperDirectory ? 3 : 0)
        )
        .overlay(alignment: .topLeading) {
            if !viewModel.selectedWallpapers.isEmpty {
                Button {
                    viewModel.toggleSelection(for: wallpaper)
                } label: {
                    Image(systemName: viewModel.isSelected(wallpaper) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(viewModel.isSelected(wallpaper) ? Color.accentColor : .white)
                }
                .buttonStyle(.plain)
                .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
                    .padding(4)
                .help("Select wallpaper")
            }
        }
        .overlay(alignment: .topTrailing) {
            if safeRestart.flaggedKeys.contains(SafeRestartLedger.key(for: wallpaper)) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
                    .padding(4)
                    .help("Open Wallpaper Engine didn't quit cleanly twice in a row while this wallpaper was showing")
            }
        }
        .border(Color.accentColor, width: viewModel.imageScaleIndex == index ? 1.0 : 0)
        .onTapGesture {
            viewModel.selectWallpaper(
                wallpaper,
                from: viewModel.autoRefreshWallpapers,
                inspectingWith: wallpaperViewModel
            )
            wallpaperViewModel.inspect(wallpaper)
        }
        .onTapGesture(count: 2) {
            wallpaperViewModel.inspect(wallpaper)
            AppDelegate.shared.showWorkshopPreview(wallpaper)
        }
    }
}
