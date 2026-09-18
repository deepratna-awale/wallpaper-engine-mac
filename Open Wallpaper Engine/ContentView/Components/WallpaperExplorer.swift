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
    
    init(contentViewModel viewModel: ContentViewModel, wallpaperViewModel: WallpaperViewModel) {
        self.viewModel = viewModel
        self.wallpaperViewModel = wallpaperViewModel
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

                InstalledPagination(viewModel: viewModel)
                .padding(.vertical, 8)
            }
            .onAppear {
                viewModel.updateInstalledItemsPerPage(for: CGSize(
                    width: geometry.size.width,
                    height: max(geometry.size.height - 44, 1)
                ))
            }
            .onChange(of: geometry.size) {
                viewModel.updateInstalledItemsPerPage(for: CGSize(
                    width: geometry.size.width,
                    height: max(geometry.size.height - 44, 1)
                ))
            }
        }
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
