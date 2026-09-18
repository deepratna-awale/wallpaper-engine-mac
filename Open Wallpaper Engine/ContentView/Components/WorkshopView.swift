import SwiftUI

struct WorkshopView: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel

    init(contentViewModel viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.steamCmd.isInstalled {
                SteamCmdNotInstalledView(steamCmd: viewModel.steamCmd)
            } else if !viewModel.steamCmd.isLoggedIn {
                SteamLoginView(steamCmd: viewModel.steamCmd)
            } else {
                WorkshopBrowserView(
                    viewModel: viewModel.workshopVM,
                    contentViewModel: viewModel
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - steamcmd Not Installed

private struct SteamCmdNotInstalledView: View {
    @ObservedObject var steamCmd: SteamCmdService
    @State private var isCopied = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("steamcmd Not Found")
                .font(.title2)
                .bold()

            Text("Steam Workshop requires steamcmd to download wallpapers.\nInstall it with Homebrew:")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack {
                Text("brew install steamcmd")
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install steamcmd", forType: .string)
                    isCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isCopied = false }
                } label: {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }

            Divider().frame(width: 200)

            Text("Or locate an existing steamcmd binary:")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("Browse...") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.message = "Select the steamcmd executable"
                if panel.runModal() == .OK, let url = panel.url {
                    steamCmd.setCustomPath(url.path)
                }
            }
            .buttonStyle(.bordered)

            if let error = steamCmd.pathError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button("Re-detect") {
                steamCmd.detectSteamCmd()
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(40)
    }
}

// MARK: - Steam Login

private struct SteamLoginView: View {
    @ObservedObject var steamCmd: SteamCmdService
    @State private var username = ""
    @State private var password = ""
    @State private var guardCode = ""
    @State private var showGuardCode = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Steam Login")
                .font(.title2)
                .bold()

            Text("Log in with your Steam account to browse and download wallpapers.\nYou must own Wallpaper Engine on Steam.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)

            VStack(spacing: 10) {
                TextField("Steam Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)

                if showGuardCode {
                    TextField("Steam Guard Code", text: $guardCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }

                if let error = steamCmd.loginError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)

                    if error.contains("Steam Guard") && !showGuardCode {
                        Button("Enter Steam Guard Code") {
                            showGuardCode = true
                        }
                        .buttonStyle(.link)
                    }
                }

                HStack(spacing: 12) {
                    Button("Log In") {
                        steamCmd.login(
                            username: username,
                            password: password,
                            guardCode: showGuardCode ? guardCode : nil
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(username.isEmpty || password.isEmpty || steamCmd.isLoggingIn)

                    if !username.isEmpty {
                        Button("Use Cached Session") {
                            steamCmd.loginWithCachedSession(username: username)
                        }
                        .buttonStyle(.bordered)
                        .disabled(steamCmd.isLoggingIn)
                    }
                }

                if steamCmd.isLoggingIn {
                    ProgressView()
                        .controlSize(.small)
                    Text("Authenticating with Steam...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // API Key section
            VStack(spacing: 6) {
                Divider().padding(.vertical, 8)
                Text("You'll also need a Steam Web API key to browse the Workshop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                APIKeyInputView {}
            }
        }
        .padding(40)
    }
}

// MARK: - Workshop Browser

private struct WorkshopBrowserView: View {
    @ObservedObject var viewModel: WorkshopViewModel
    @ObservedObject var contentViewModel: ContentViewModel

    var body: some View {
        HStack(spacing: 0) {
            WorkshopFiltersSidebar(viewModel: viewModel)
                .frame(width: contentViewModel.isFilterReveal ? 225 : 0)
                .opacity(contentViewModel.isFilterReveal ? 1 : 0)

            workshopContent
                .padding(.leading, contentViewModel.isFilterReveal ? 10 : 0)
        }
        .animation(.spring(), value: contentViewModel.isFilterReveal)
        .confirmationDialog(
            "Download Selected Wallpapers",
            isPresented: $viewModel.isBatchDownloadConfirming
        ) {
            Button("Download \(viewModel.selectedItemIds.count) Wallpapers") {
                viewModel.downloadSelectedItems()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Download \(viewModel.selectedItemIds.count) selected wallpapers to your library?")
        }
    }

    private var workshopContent: some View {
        VStack(spacing: 8) {
            // Search bar
            HStack {
                if viewModel.authorId != nil {
                    Label("Author Workshop", systemImage: "person.fill")
                        .foregroundStyle(.secondary)
                    Button {
                        viewModel.clearAuthorFilter()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("Clear author filter")
                }
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search wallpapers...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        viewModel.currentPage = 1
                        Task { await viewModel.search() }
                    }
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                        viewModel.currentPage = 1
                        Task { await viewModel.search() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Picker("Sort", selection: $viewModel.sortOrder) {
                    ForEach(WorkshopSortOrder.allCases) { order in
                        Text(order.displayName).tag(order)
                    }
                }
                .frame(width: 160)
                .onChange(of: viewModel.sortOrder) {
                    viewModel.currentPage = 1
                    Task { await viewModel.search() }
                }

                Button {
                    contentViewModel.isFilterReveal.toggle()
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.bordered)
                .help("Show filters")

                if !viewModel.selectedItemIds.isEmpty {
                    Button {
                        viewModel.isBatchDownloadConfirming = true
                    } label: {
                        Label("Download Selected (\(viewModel.selectedItemIds.count))", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        viewModel.clearSelection()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .help("Clear selection")
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)

            // Results
            if viewModel.isLoading && viewModel.items.isEmpty {
                Spacer()
                ProgressView("Searching Workshop...")
                Spacer()
            } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    APIKeyInputView {
                        Task { await viewModel.search() }
                    }
                }
                Spacer()
            } else if viewModel.items.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Search the Steam Workshop")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Find wallpapers by name, tag, or browse trending content.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)

                    if WorkshopAPIService.loadAPIKey().isEmpty {
                        Divider().frame(width: 300).padding(.vertical, 4)
                        Text("A Steam Web API key is required to browse.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        APIKeyInputView {
                            Task { await viewModel.search() }
                        }
                    }
                }
                Spacer()
            } else {
                GeometryReader { geometry in
                    VStack(spacing: 8) {
                        LazyVGrid(columns: [
                            GridItem(
                                .adaptive(
                                    minimum: contentViewModel.explorerIconSize - 5,
                                    maximum: contentViewModel.explorerIconSize - 5
                                ),
                                spacing: 13
                            )
                        ], alignment: .leading, spacing: 13) {
                            ForEach(viewModel.visibleItems) { item in
                                WorkshopItemCard(item: item, viewModel: viewModel)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                        WorkshopPagination(viewModel: viewModel)
                            .padding(.bottom, 8)
                    }
                    .onAppear {
                        Task {
                            await viewModel.updateItemsPerPage(
                                for: CGSize(width: geometry.size.width, height: max(geometry.size.height - 44, 1)),
                                itemSize: contentViewModel.explorerIconSize - 5
                            )
                        }
                    }
                    .onChange(of: geometry.size) {
                        Task {
                            await viewModel.updateItemsPerPage(
                                for: CGSize(width: geometry.size.width, height: max(geometry.size.height - 44, 1)),
                                itemSize: contentViewModel.explorerIconSize - 5
                            )
                        }
                    }
                }
            }
        }
        .task {
            if viewModel.items.isEmpty {
                await viewModel.search()
            }
        }
    }
}

private struct WorkshopPagination: View {
    @ObservedObject var viewModel: WorkshopViewModel

    var body: some View {
        HStack(spacing: 6) {
            Button {
                viewModel.currentPage -= 1
                Task { await viewModel.search() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(viewModel.currentPage == 1 || viewModel.isLoading)

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
                Task { await viewModel.search() }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!viewModel.hasNextPage || viewModel.isLoading)
        }
    }

    private var pageNumbers: [Int] {
        let firstPage = max(1, viewModel.currentPage - 2)
        let lastPage = viewModel.hasNextPage ? viewModel.currentPage + 2 : viewModel.currentPage
        return Array(firstPage...lastPage)
    }

    private func pageButton(_ page: Int) -> some View {
        Button("\(page)") {
            viewModel.currentPage = page
            Task { await viewModel.search() }
        }
        .disabled(viewModel.isLoading)
    }
}

private struct WorkshopFiltersSidebar: View {
    @ObservedObject var viewModel: WorkshopViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button {
                    viewModel.resetFilters()
                    Task { await viewModel.search() }
                } label: {
                    Label("Reset Filters", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Toggle("Hide Downloaded", isOn: $viewModel.hideDownloaded)
                    .toggleStyle(.checkbox)
                    .onChange(of: viewModel.hideDownloaded) {
                        viewModel.currentPage = 1
                        Task { await viewModel.search() }
                    }

                filterSection("Rating", tags: WorkshopViewModel.contentRatingTags)
                filterSection("Type", tags: WorkshopViewModel.typeTags)
                filterSection("Resolution", tags: WorkshopViewModel.resolutionTags)
                filterSection("Genre", tags: WorkshopViewModel.genreTags)
            }
            .padding()
        }
    }

    private func filterSection(_ title: LocalizedStringKey, tags: [String]) -> some View {
        FilterSection(title, alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Toggle(tag, isOn: Binding(
                    get: { viewModel.selectedTags.contains(tag) },
                    set: { isSelected in
                        if isSelected != viewModel.selectedTags.contains(tag) {
                            viewModel.toggleTag(tag)
                            Task { await viewModel.search() }
                        }
                    }
                ))
            }
            .toggleStyle(.checkbox)
        }
    }
}

// MARK: - Workshop Item Card

private struct WorkshopItemCard: View {
    let item: WorkshopItem
    @ObservedObject var viewModel: WorkshopViewModel

    var body: some View {
        ZStack(alignment: .bottom) {
            AsyncImage(url: item.previewImageURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(1, contentMode: .fill)
                case .failure:
                    placeholder
                default:
                    placeholder
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()

            Text(item.title)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
                .padding(4)
                .background(Color(white: 0, opacity: 0.65))
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
        }
        .overlay(alignment: .topTrailing) {
            downloadControl
                .padding(6)
                .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
        }
        .overlay(alignment: .topLeading) {
            if !viewModel.selectedItemIds.isEmpty {
                Button {
                    viewModel.selectItem(item)
                } label: {
                    Image(systemName: viewModel.selectedItemIds.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(viewModel.selectedItemIds.contains(item.id) ? Color.accentColor : .white)
                }
                .buttonStyle(.plain)
                .padding(6)
                .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
                .help("Select item")
            }
        }
        .border(Color(nsColor: .separatorColor), width: 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectItem(item)
        }
        .onTapGesture(count: 2) {
            viewModel.preview(item: item)
        }
    }

    @ViewBuilder
    private var downloadControl: some View {
        if viewModel.isPreviewLoading(item) {
            ProgressView()
                .controlSize(.small)
                .help("Preparing preview")
        } else {
        let state = viewModel.downloadState(for: item)
        switch state {
        case .downloading(let status):
            ProgressView()
                .controlSize(.small)
                .help(status)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Downloaded")
        case .failed(let msg):
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .help(msg)
        case .none:
            if viewModel.steamCmd.isLoggedIn {
                Button {
                    viewModel.download(item: item)
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("Download")
            } else {
                Image(systemName: "person.badge.key")
                    .foregroundStyle(.secondary)
                    .help("Log in to download")
            }
        }
            }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - API Key Input

private struct APIKeyInputView: View {
    @State private var apiKey = WorkshopAPIService.loadAPIKey()
    var onSave: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Steam Web API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .onSubmit { save() }

                Button("Save & Search") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(spacing: 4) {
                Text("Get a free key at")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Link("steamcommunity.com/dev/apikey", destination: URL(string: "https://steamcommunity.com/dev/apikey")!)
                    .font(.caption)
            }
        }
    }

    private func save() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        WorkshopAPIService.saveAPIKey(trimmed)
        onSave()
    }
}
