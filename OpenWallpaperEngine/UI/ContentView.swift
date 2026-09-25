//
//  ContentView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/6/5.
//

import SwiftUI

protocol SubviewOfContentView: View {
    var viewModel: ContentViewModel { get set }
    
//    init(contentViewModel viewModel: ContentViewModel)
}

struct ContentView: View {
    @EnvironmentObject var globalSettingsViewModel: GlobalSettingsViewModel
    
    @ObservedObject var viewModel: ContentViewModel
    
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    
    @State var isDropTargeted = false
    @State var isParseFinished = false
    @State var isFilterReveal = true
    
    @State var isDockIconHidden = false
    
    @State var project: WEProject!
    @State var projectUrl: URL!
    @State var greet: String = "Hello, world!"
    @State private var isRemoteWallpaperSheetPresented = false
    
    var body: some View {
        ZStack {
            HSplitView {
                if viewModel.isStaging {
                    VStack(spacing: 5) {
                        TopTabBar(contentViewModel: viewModel)
                        switch viewModel.topTabBarSelection {
                        case 0:
                            ExplorerTopBar(contentViewModel: viewModel)
                                .environmentObject(globalSettingsViewModel)
                            HStack(spacing: 0) {
                                HStack(spacing: 0) {
                                    // MARK: Filter Results
                                    FilterResults(viewModel: viewModel)
                                }
                                .frame(width: viewModel.isFilterReveal ? 225 : 0)
                                .opacity(viewModel.isFilterReveal ? 1 : 0)
                                .animation(.spring(), value: viewModel.isFilterReveal)
                                
                                WallpaperExplorer(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel)
                                .onDrop(of: [.fileURL], delegate: viewModel)
                                .contextMenu {
                                    ExplorerGlobalMenu(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel)
                                }
                                .padding(.leading, viewModel.isFilterReveal ? 10 : 0)
                            }
                            .animation(.default, value: viewModel.isFilterReveal)
                        case 1:
                            WorkshopView(contentViewModel: viewModel)
                        case 2:
                            DownloadsView(steamCmd: viewModel.steamCmd)
                        case 3:
                            PlaylistView(wallpaperViewModel: wallpaperViewModel)
                        default:
                            fatalError()
                        }
                        if viewModel.topTabBarSelection == 0 {
                            HStack {
                                Button {
                                    AppDelegate.shared.openImportFromFolderPanel()
                                } label: {
                                    Label("Open Wallpaper", systemImage: "arrow.up.bin.fill")
                                        .frame(width: 220)
                                }
                                Button {
                                    AppDelegate.shared.openImportVideoPanel()
                                } label: {
                                    Label("Add Video Wallpaper", systemImage: "film.stack")
                                }
                                Button {
                                    isRemoteWallpaperSheetPresented = true
                                } label: {
                                    Label("Add Video/Image URL", systemImage: "link")
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding()
                    if viewModel.topTabBarSelection == 0 {
                        WallpaperPreview(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel)
                            .frame(maxWidth: 320)
                    }
                }
            }
            .opacity(viewModel.isStaging ? 1 : 0)
            .blur(radius: viewModel.isStaging ? 0 : 2.0)
            
            // indicate that this view is initializing
            if !viewModel.isStaging {
                HStack(spacing: 20) {
                    Text("Power Saving Mode, Sleeping...")
                        .font(.largeTitle)
                }
            }

            if viewModel.isDisplaySettingsReveal {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.isDisplaySettingsReveal = false
                    }

                DisplaySettings(viewModel: viewModel)
                    .padding()
                    .frame(width: 520, height: 450)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .cornerRadius(8)
                    .shadow(radius: 20)
            }
        }
        .confirmationDialog("Unsubscribe Confirmation",
                            isPresented: $viewModel.isUnsubscribeConfirming) {
            if let url = viewModel.hoveredWallpaper?.wallpaperDirectory {
                Button("Delete Immediately", role: .destructive) {
                    if (try? FileManager.default.removeItem(at: url)) != nil {
                        DownloadedWallpaperIndex.shared.remove(directory: url)
                    }
                    wallpaperViewModel.removeWallpaperFromAllScreens(directory: url)
                    viewModel.hoveredWallpaper = nil
                    viewModel.removeUnusedWorkshopDependencies()
                }
                Button("Move to Trash") {
                    if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil {
                        DownloadedWallpaperIndex.shared.remove(directory: url)
                    }
                    wallpaperViewModel.removeWallpaperFromAllScreens(directory: url)
                    viewModel.hoveredWallpaper = nil
                    viewModel.removeUnusedWorkshopDependencies()
                }
            }
            Button("Cancel", role: .cancel) {
                viewModel.hoveredWallpaper = nil
            }
        } message: {
            Text("\(viewModel.hoveredWallpaper?.project.title ?? "invalid wallpaper")")
        }
        .confirmationDialog("Batch Unsubscribe Confirmation",
                            isPresented: $viewModel.isBatchUnsubscribeConfirming) {
            Button("Delete All \(viewModel.selectedWallpapers.count) Immediately", role: .destructive) {
                for url in viewModel.selectedWallpapers {
                    if (try? FileManager.default.removeItem(at: url)) != nil {
                        DownloadedWallpaperIndex.shared.remove(directory: url)
                    }
                    wallpaperViewModel.removeWallpaperFromAllScreens(directory: url)
                }
                viewModel.clearSelection()
                viewModel.removeUnusedWorkshopDependencies()
            }
            Button("Move All \(viewModel.selectedWallpapers.count) to Trash") {
                for url in viewModel.selectedWallpapers {
                    if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil {
                        DownloadedWallpaperIndex.shared.remove(directory: url)
                    }
                    wallpaperViewModel.removeWallpaperFromAllScreens(directory: url)
                }
                viewModel.clearSelection()
                viewModel.removeUnusedWorkshopDependencies()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let items = viewModel.selectedWallpaperItems()
            let names = items.prefix(3).map(\.project.title).joined(separator: ", ")
            let suffix = items.count > 3 ? " and \(items.count - 3) more" : ""
            Text("Unsubscribe \(items.count) wallpapers: \(names)\(suffix)")
        }
        .alert(isPresented: $viewModel.importAlertPresented, error: viewModel.importAlertError) {

        }
        .sheet(isPresented: $globalSettingsViewModel.isFirstLaunch) {
            FirstLaunchView()
                .environmentObject(globalSettingsViewModel)
        }
        .sheet(isPresented: $viewModel.isUnsafeWallpaperWarningPresented) {
            UnsafeWallpaper(wallpaper: wallpaperViewModel.nextCurrentWallpaper)
                .frame(width: 600, height: 300)
        }
        .sheet(isPresented: $isRemoteWallpaperSheetPresented) {
            RemoteWallpaperURLSheet(wallpaperViewModel: wallpaperViewModel)
                .frame(width: 500, height: 180)
        }
        .frame(minWidth: 1000, minHeight: 640, idealHeight: 800)
    }
}

private struct RemoteWallpaperURLSheet: View {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var urlString = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Video/Image URL").font(.headline)
            TextField("https://example.com/wallpaper.mp4", text: $urlString)
                .textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    guard let url = URL(string: urlString),
                          ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                        error = "Enter a valid HTTP or HTTPS image/video URL."
                        return
                    }
                    let extensionName = url.pathExtension.lowercased()
                    guard ["jpg", "jpeg", "png", "gif", "webp", "heic", "mp4", "mov", "m4v", "webm"].contains(extensionName) else {
                        error = "The URL must end in a supported image or video extension."
                        return
                    }
                    wallpaperViewModel.addRemoteWallpaper(from: url)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }
}

struct DownloadQueuePanel: View {
    @ObservedObject var steamCmd: SteamCmdService
    @State private var isExpanded = true

    private var failedDownloadIds: [String] {
        steamCmd.downloadProgress.compactMap { workshopId, state in
            if case .failed = state {
                return workshopId
            }
            return nil
        }
        .sorted()
    }

    private var queuedDownloadIds: [String] {
        steamCmd.queuedDownloadIds.filter { $0 != steamCmd.activeDownloadId }
    }

    private var hasDownloads: Bool {
        steamCmd.activeDownloadId != nil || !queuedDownloadIds.isEmpty || !failedDownloadIds.isEmpty
    }

    var body: some View {
        if hasDownloads {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    if let activeId = steamCmd.activeDownloadId {
                        statusRow(workshopId: activeId, label: "Downloading")
                    }

                    ForEach(queuedDownloadIds, id: \.self) { workshopId in
                        statusRow(workshopId: workshopId, label: "Queued")
                    }

                    ForEach(failedDownloadIds, id: \.self) { workshopId in
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(downloadTitle(for: workshopId))
                                .lineLimit(1)
                            Spacer()
                            Button {
                                steamCmd.downloadWorkshopItem(
                                    workshopId: workshopId,
                                    title: steamCmd.downloadTitles[workshopId]
                                )
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .help(failureMessage(for: workshopId))
                        }
                        .font(.caption)
                    }
                }
                .padding(.top, 6)
            } label: {
                Label(panelTitle, systemImage: "arrow.down.circle")
                    .font(.callout.weight(.medium))
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .frame(maxWidth: 480, alignment: .leading)
        }
    }

    private var panelTitle: String {
        if !failedDownloadIds.isEmpty {
            return "Downloads: \(failedDownloadIds.count) failed"
        }
        return "Downloads: \(steamCmd.queuedDownloadIds.count)"
    }

    private func statusRow(workshopId: String, label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(downloadTitle(for: workshopId))
                .lineLimit(1)
            Spacer()
            Text(label)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func downloadTitle(for workshopId: String) -> String {
        steamCmd.downloadTitles[workshopId] ?? "Workshop item \(workshopId)"
    }

    private func failureMessage(for workshopId: String) -> String {
        guard case let .failed(message) = steamCmd.downloadProgress[workshopId] else { return "Retry download" }
        return message
    }
}

private struct DownloadsView: View {
    @ObservedObject var steamCmd: SteamCmdService

    private var downloadIds: [String] {
        let failedIds = steamCmd.downloadProgress.compactMap { workshopId, state in
            if case .failed = state { return workshopId }
            return nil
        }
        let completedIds = steamCmd.downloadProgress.compactMap { workshopId, state in
            if case .completed = state { return workshopId }
            return nil
        }
        return Array(Set((steamCmd.activeDownloadId.map { [$0] } ?? [])
            + steamCmd.queuedDownloadIds
            + failedIds
            + completedIds))
        .sorted { left, right in
            let leftIndex = steamCmd.queuedDownloadIds.firstIndex(of: left) ?? Int.max
            let rightIndex = steamCmd.queuedDownloadIds.firstIndex(of: right) ?? Int.max
            return leftIndex < rightIndex
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Downloads")
                .font(.title2)
                .fontWeight(.semibold)

            if downloadIds.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Workshop downloads and failed retries appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(downloadIds, id: \.self) { workshopId in
                            DownloadRow(workshopId: workshopId, steamCmd: steamCmd)
                        }
                    }
                }
            }
        }
        .padding()
    }
}

private struct DownloadRow: View {
    let workshopId: String
    @ObservedObject var steamCmd: SteamCmdService

    private var item: SteamCmdService.DownloadItem? {
        steamCmd.downloadItems[workshopId]
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                AsyncImage(url: item?.previewURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Rectangle().fill(Color(nsColor: .separatorColor))
                    }
                }
                .frame(width: 112, height: 72)
                .clipped()

                VStack(alignment: .leading, spacing: 6) {
                    Text(item?.title ?? steamCmd.downloadTitles[workshopId] ?? "Workshop item \(workshopId)")
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 12) {
                        if let creatorId = item?.creatorId {
                            Label(
                                SteamPlayerStore.shared.player(for: creatorId)?.personaName ?? creatorId,
                                systemImage: "person"
                            )
                        }
                        if let subscriptions = item?.subscriptions, subscriptions > 0 {
                            Label(formatCount(subscriptions), systemImage: "heart")
                        }
                        if let fileSize = item?.fileSize, fileSize > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if case .failed = steamCmd.downloadProgress[workshopId] {
                    Button {
                        steamCmd.downloadWorkshopItem(
                            workshopId: workshopId,
                            title: item?.title ?? steamCmd.downloadTitles[workshopId],
                            previewURL: item?.previewURL,
                            creatorId: item?.creatorId,
                            subscriptions: item?.subscriptions ?? 0,
                            fileSize: item?.fileSize ?? 0
                        )
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .help(failureMessage)
                }
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 8) {
                    ProgressView(value: progress(at: context.date))
                        .tint(progressColor)
                    if let percentage = steamCmd.downloadPercentages[workshopId],
                       isDownloading {
                        Text("\(Int((percentage * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }

            HStack {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(workshopId)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private var statusText: String {
        guard let state = steamCmd.downloadProgress[workshopId] else { return "Queued" }
        switch state {
        case .downloading(let status): return status
        case .completed: return "Downloaded"
        case .failed(let message): return message
        }
    }

    private var progressColor: Color {
        guard let state = steamCmd.downloadProgress[workshopId] else { return .accentColor }
        switch state {
        case .completed: return .green
        case .failed: return .red
        case .downloading: return .accentColor
        }
    }

    private var isDownloading: Bool {
        if case .downloading = steamCmd.downloadProgress[workshopId] {
            return true
        }
        return false
    }

    private func progress(at date: Date) -> Double {
        guard let state = steamCmd.downloadProgress[workshopId] else { return 0.05 }
        switch state {
        case .completed, .failed:
            return 1
        case .downloading(let status):
            if status == "Queued" { return 0.05 }
            if status.contains("Copying") { return 0.92 }
            if let percentage = steamCmd.downloadPercentages[workshopId], percentage > 0 {
                return percentage
            }
            let startedAt = steamCmd.downloadStartedAt[workshopId] ?? date
            return min(0.88, 0.18 + date.timeIntervalSince(startedAt) / 180 * 0.7)
        }
    }

    private var failureMessage: String {
        guard case let .failed(message) = steamCmd.downloadProgress[workshopId] else { return "Retry download" }
        return message
    }

    private func formatCount(_ count: Int) -> String {
        count >= 1_000 ? String(format: "%.1fK", Double(count) / 1_000) : "\(count)"
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(viewModel: .init(isStaging: true), wallpaperViewModel: .init())
            .environmentObject(GlobalSettingsViewModel())
    }
}
