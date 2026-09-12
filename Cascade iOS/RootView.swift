#if os(iOS)
import SwiftUI
import PDFKit
import VisionKit
import PhotosUI

// MARK: - Reusable Blue Ellipsis Menu Button

struct BlueEllipsisMenu<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(XTheme.accent)
        }
    }
}

// MARK: - Reusable Blue Add Menu Button

struct BlueAddMenu<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(XTheme.accent)
        }
    }
}

// MARK: - Standard Add Menu

struct StandardAddMenu: View {
    var folderID: String? = nil
    var isPrivate: Bool = false
    @Environment(AppState.self) private var appState

    var body: some View {
        BlueAddMenu {
            Button {
                appState.triggerPhotoUpload(in: folderID, isPrivate: isPrivate)
            } label: {
                Label("Upload Photos & Videos", systemImage: "photo.on.rectangle")
            }

            Button {
                appState.triggerFileUpload(in: folderID, isPrivate: isPrivate)
            } label: {
                Label("Upload Files", systemImage: "arrow.up.doc")
            }

            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    appState.triggerCameraCapture(in: folderID, isPrivate: isPrivate)
                } label: {
                    Label("Take Photo or Video", systemImage: "camera")
                }
            }

            Button {
                appState.startDocumentScan(in: folderID)
            } label: {
                Label("Scan Documents", systemImage: "document.viewfinder")
            }

            Divider()

            Button {
                appState.startCreatingFolder(in: folderID)
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }

            Divider()

            Button {
                appState.showImportShareSheet = true
            } label: {
                Label("Add from Share Link…", systemImage: "link.badge.plus")
            }
        }
    }
}


// MARK: - Zoomable Interactive Image View

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 5.0
        scrollView.minimumZoomScale = 1.0
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.tag = 999
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])

        let doubleTapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTapGesture.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTapGesture)

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        if let imageView = uiView.viewWithTag(999) as? UIImageView {
            imageView.image = image
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            scrollView.viewWithTag(999)
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1.0 {
                scrollView.setZoomScale(1.0, animated: true)
            } else {
                let center = gesture.location(in: scrollView)
                let zoomRect = CGRect(x: center.x - 50, y: center.y - 50, width: 100, height: 100)
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }
    }
}

// MARK: - Reusable Bottom Item Count Footer

struct PageItemCountFooter: View {
    let count: Int
    var noun: String = "item"
    var showSyncStatus: Bool = true

    var body: some View {
        VStack(spacing: 4) {
            Text("\(count) \(count == 1 ? noun : "\(noun)s")")
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
            if showSyncStatus {
                Text("Synced with Cascade")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 20)
    }
}

// MARK: - Reusable Search Empty State

struct NoSearchResultsView: View {
    let query: String

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(XTheme.accent)
            Text("No Results")
                .font(.title2.bold())
            Text("No results found for “\(query)”.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }
}

// MARK: - Share Sheet Helper

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - PDFKit Represented View

struct PDFKitRepresentedView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.document = PDFDocument(url: url)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        if pdfView.document?.documentURL != url {
            pdfView.document = PDFDocument(url: url)
        }
    }
}

// MARK: - VisionKit Document Scanner View

struct DocumentScannerView: UIViewControllerRepresentable {
    var onScanComplete: (URL) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView

        init(_ parent: DocumentScannerView) {
            self.parent = parent
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let pdfDocument = PDFDocument()
            for pageIndex in 0..<scan.pageCount {
                let image = scan.imageOfPage(at: pageIndex)
                if let pdfPage = PDFPage(image: image) {
                    pdfDocument.insert(pdfPage, at: pageIndex)
                }
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let timestamp = formatter.string(from: Date())
            let fileName = "Scanned Document \(timestamp).pdf"
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

            if pdfDocument.write(to: tempURL) {
                controller.dismiss(animated: true) {
                    self.parent.onScanComplete(tempURL)
                }
            } else {
                controller.dismiss(animated: true) {
                    self.parent.onCancel()
                }
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true) {
                self.parent.onCancel()
            }
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            print("[DocumentScanner] Scanner failed with error: \(error.localizedDescription)")
            controller.dismiss(animated: true) {
                self.parent.onCancel()
            }
        }
    }
}

// MARK: - File Quick Look / Preview View

struct FilePreviewView: View {
    let file: FileItem
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0
    @State private var downloadStatus: String = ""
    @State private var localURL: URL? = nil
    @State private var textContent: String? = nil
    @State private var showShareSheet = false
    @State private var showInfo = false
    @State private var errorMessage: String? = nil
    @State private var showControls = true

    private var isPDF: Bool {
        file.name.lowercased().hasSuffix(".pdf") || file.mime == "application/pdf"
    }

    private var isText: Bool {
        let ext = (file.name as NSString).pathExtension.lowercased()
        return ["txt", "md", "markdown", "json", "csv", "swift", "py", "sh", "log"].contains(ext) || file.mime.hasPrefix("text/")
    }

    /// Whether the current file resolves to an image that can be displayed full-screen.
    private var isImageContent: Bool {
        file.isImage || (localURL != nil && loadedImage(for: localURL!) != nil)
    }

    var body: some View {
        ZStack {
            // Black background for media/photos, system background for text/docs
            Color.black.ignoresSafeArea()

            if let localURL {
                if let uiImage = loadedImage(for: localURL) {
                    ZoomableImageView(image: uiImage)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showControls.toggle()
                            }
                        }
                } else if isPDF {
                    PDFKitRepresentedView(url: localURL)
                        .edgesIgnoringSafeArea(.bottom)
                } else if isText, let textContent {
                    ScrollView {
                        Text(textContent)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    cachedFileFallback(localURL)
                }
            } else if isDownloading {
                if file.isImage, let thumb = placeholderThumbnail {
                    ZStack {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .blur(radius: 2)
                            .ignoresSafeArea()

                        VStack(spacing: 8) {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(1.2)
                            Text(downloadStatus.isEmpty ? "Loading full resolution…" : downloadStatus)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                } else {
                    downloadingView
                }
            } else {
                notDownloadedView
            }
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(isImageContent && !showControls ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") {
                    dismiss()
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(XTheme.accent)
            }

            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    if let localURL {
                        Button {
                            showShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(XTheme.accent)
                        }
                    } else if !isDownloading {
                        Button {
                            startDownload()
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(XTheme.accent)
                        }
                    }

                    BlueEllipsisMenu {
                        Button {
                            appState.toggleFavorite(file)
                        } label: {
                            Label(file.isFavorite ? "Unfavorite" : "Favorite", systemImage: file.isFavorite ? "heart.slash" : "heart")
                        }

                        Button {
                            appState.togglePin(file)
                        } label: {
                            Label(file.isPinned ? "Remove Download" : "Keep Downloaded", systemImage: file.isPinned ? "arrow.down.circle.fill" : "arrow.down.circle")
                        }

                        Divider()

                        Button {
                            showInfo = true
                        } label: {
                            Label("Get Info", systemImage: "info.circle")
                        }

                        Divider()

                        Button(role: .destructive) {
                            appState.trashFile(file)
                            dismiss()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .statusBarHidden(isImageContent && !showControls)
        .sheet(isPresented: $showShareSheet) {
            if let localURL {
                ShareSheet(items: [localURL])
            }
        }
        .alert("File Info", isPresented: $showInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.getInfo(file))
        }
        .task {
            checkLocalFile()
            if localURL == nil && (file.isImage || file.size < 15 * 1024 * 1024) && !file.isFolder {
                startDownload()
            }
        }
    }

    private func loadedImage(for url: URL) -> UIImage? {
        if let img = UIImage(contentsOfFile: url.path) {
            return img
        }
        if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
            return img
        }
        return nil
    }

    private var placeholderThumbnail: UIImage? {
        if let data = file.thumbnailData, let img = UIImage(data: data) {
            return img
        }
        if let diskURL = UploadEngine.thumbnailURL(for: file.id),
           let data = try? Data(contentsOf: diskURL),
           let img = UIImage(data: data) {
            return img
        }
        return nil
    }

    private func checkLocalFile() {
        if appState.isCached(file) {
            let url = appState.cachedURL(for: file)
            self.localURL = url
            if isText, let content = try? String(contentsOf: url) {
                self.textContent = content
            }
        }
    }

    private func startDownload() {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        downloadStatus = "Starting download…"
        errorMessage = nil

        Task {
            do {
                if let url = try await appState.downloadFile(file, progress: { status, p in
                    Task { @MainActor in
                        self.downloadStatus = status
                        self.downloadProgress = p
                    }
                }) {
                    await MainActor.run {
                        self.localURL = url
                        self.isDownloading = false
                        if self.isText, let content = try? String(contentsOf: url) {
                            self.textContent = content
                        }
                    }
                } else {
                    await MainActor.run {
                        self.errorMessage = "Download failed."
                        self.isDownloading = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isDownloading = false
                }
            }
        }
    }

    private var downloadingView: some View {
        VStack(spacing: 20) {
            if let thumbData = file.thumbnailData, let img = UIImage(data: thumbData) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .opacity(0.7)
            } else {
                Image(systemName: file.systemIcon)
                    .font(.system(size: 64))
                    .foregroundStyle(XTheme.accent)
            }

            VStack(spacing: 8) {
                Text(downloadStatus.isEmpty ? "Downloading…" : downloadStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ProgressView(value: downloadProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 200)

                Text("\(Int(downloadProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(32)
    }

    private var notDownloadedView: some View {
        VStack(spacing: 20) {
            if let thumbData = file.thumbnailData, let img = UIImage(data: thumbData) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 4)
            } else {
                Image(systemName: file.systemIcon)
                    .font(.system(size: 64))
                    .foregroundStyle(XTheme.accent)
            }

            VStack(spacing: 6) {
                Text(file.name)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                if let size = file.formattedSize {
                    Text(size)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text("Created \(file.formattedDate)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.top, 4)
                }
            }

            Button {
                startDownload()
            } label: {
                Label("Download File", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .padding(32)
    }

    private func cachedFileFallback(_ url: URL) -> some View {
        VStack(spacing: 20) {
            Image(systemName: file.systemIcon)
                .font(.system(size: 64))
                .foregroundStyle(XTheme.accent)

            VStack(spacing: 6) {
                Text(file.name)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                if let size = file.formattedSize {
                    Text(size)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text("Downloaded")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
            }

            Button {
                showShareSheet = true
            } label: {
                Label("Share or Export", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}

// MARK: - Root View

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Tab = .browse
    @State private var selectedPhotoItems: [PhotosPickerItem] = []

    enum Tab: Hashable {
        case recents
        case shared
        case browse
    }

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.08)
                .ignoresSafeArea()

            if appState.isInitialLoading {
                loadingView
            } else if appState.isAuthorized {
                mainTabs
            } else {
                LoginGateView()
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 20) {
            Image("CascadeLogo")
                .resizable()
                .renderingMode(.original)
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
            ProgressView()
                .tint(XTheme.accent)
        }
    }

    private var mainTabs: some View {
        @Bindable var appState = appState
        return TabView(selection: $selectedTab) {
            RecentsView()
                .tag(Tab.recents)

            SharedView()
                .tag(Tab.shared)

            BrowseView(selectedTab: $selectedTab)
                .tag(Tab.browse)
        }
        .toolbar(.hidden, for: .tabBar)
        .fullScreenCover(isPresented: $appState.showDocumentScanner) {
            DocumentScannerView(
                onScanComplete: { pdfURL in
                    let targetFolderID = appState.scannerTargetFolderID
                    appState.showDocumentScanner = false
                    Task {
                        await appState.uploadBatch(urls: [pdfURL], parentID: targetFolderID)
                    }
                },
                onCancel: {
                    appState.showDocumentScanner = false
                }
            )
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $appState.theaterFile) { file in
            NavigationStack {
                VideoPlaybackView(file: file)
            }
        }
        .fullScreenCover(item: Binding(
            get: {
                if let file = appState.presentedFile, !file.isVideo, !file.isAudio {
                    return file
                }
                return nil
            },
            set: { appState.presentedFile = $0 }
        )) { file in
            NavigationStack {
                FilePreviewView(file: file)
            }
        }
        .photosPicker(
            isPresented: $appState.showPhotosPicker,
            selection: $selectedPhotoItems,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            let picked = items
            selectedPhotoItems = []
            Task {
                await appState.uploadPhotos(picked, folderID: appState.uploadTargetFolderID, isPrivate: appState.uploadTargetIsPrivate)
            }
        }
        .fileImporter(
            isPresented: $appState.showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task {
                    await appState.uploadBatch(urls: urls, parentID: appState.uploadTargetFolderID, isPrivate: appState.uploadTargetIsPrivate)
                }
            }
        }
        .fullScreenCover(isPresented: $appState.showCameraPicker) {
            CameraMediaPicker { url in
                Task {
                    await appState.uploadBatch(urls: [url], parentID: appState.uploadTargetFolderID, isPrivate: appState.uploadTargetIsPrivate)
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                appState.isVaultLocked = true
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                if appState.isUploading {
                    HStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(0.8)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(appState.uploadStatus.isEmpty ? "Uploading..." : appState.uploadStatus)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            ProgressView(value: max(0.02, appState.uploadProgress))
                                .progressViewStyle(.linear)
                                .tint(XTheme.accent)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if let track = appState.currentAudioTrack {
                    AudioMiniPlayerView(track: track)
                        .padding(.horizontal, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                CustomGlassTabBar(selectedTab: $selectedTab)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: appState.isUploading)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: appState.currentAudioTrack != nil)
        }
        .sheet(isPresented: $appState.showFullAudioPlayer) {
            if let track = appState.currentAudioTrack {
                FullAudioPlayerView(track: track)
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(item: $appState.shareSheetTargetFile) { file in
            ShareFileSheet(file: file)
        }
        .sheet(item: Binding(
            get: { appState.moveSheetFileIDs.map { MoveSheetWrapper(ids: $0) } },
            set: { appState.moveSheetFileIDs = $0?.ids }
        )) { wrapper in
            MoveDestinationPickerSheet(fileIDs: wrapper.ids)
        }
        .sheet(item: Binding(
            get: { appState.shareActivityItems.map { ActivityItemsWrapper(items: $0) } },
            set: { appState.shareActivityItems = $0?.items }
        )) { wrapper in
            ShareSheet(items: wrapper.items)
        }
        .sheet(isPresented: $appState.showImportShareSheet) {
            ImportShareLinkSheet()
        }
    }
}

// MARK: - Bespoke Frosted Glass Bottom Navigation Bar

struct CustomGlassTabBar: View {
    @Environment(AppState.self) private var appState
    @Binding var selectedTab: RootView.Tab

    var body: some View {
        HStack(spacing: 0) {
            tabButton(tab: .recents, title: "Recents", icon: "clock")
            tabButton(tab: .shared, title: "Shared", icon: "arrow.triangle.swap")
            tabButton(tab: .browse, title: "Browse", icon: "folder.fill")
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: 24,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 24,
                style: .continuous
            )
            .fill(.ultraThinMaterial)
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 24,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 24,
                    style: .continuous
                )
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.18),
                            Color.white.opacity(0.06),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: -4)
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private func tabButton(tab: RootView.Tab, title: String, icon: String) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            if selectedTab != tab {
                UISelectionFeedbackGenerator().selectionChanged()
                withAnimation(.easeInOut(duration: 0.18)) {
                    selectedTab = tab
                }
            } else if tab == .browse {
                UISelectionFeedbackGenerator().selectionChanged()
                withAnimation(.easeInOut(duration: 0.2)) {
                    appState.currentFolderID = ""
                    appState.currentFolderName = "All Files"
                    appState.folderStack.removeAll()
                    appState.browseNavPath.removeAll()
                }
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: isSelected ? .bold : .medium))
                    .frame(height: 24)
                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
            }
            .foregroundStyle(isSelected ? XTheme.accent : Color(white: 0.52))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Browse Destination Enum

enum BrowseDestination: Hashable {
    case allFiles
    case privateVault
    case favorites
    case photos
    case videos
    case audio
    case documents
    case library
    case transfers
    case archive
    case trash
}

// MARK: - Browse View (Cascade Bespoke Dashboard)

struct BrowseView: View {
    @Environment(AppState.self) private var appState
    @Binding var selectedTab: RootView.Tab
    @State private var searchText = ""
    @State private var showSettings = false

    var body: some View {
        @Bindable var bindableAppState = appState
        return NavigationStack(path: $bindableAppState.browseNavPath) {
            ScrollView {
                VStack(spacing: 20) {
                    if !searchText.isEmpty {
                        browseSearchResults
                    } else {
                        profileHeaderCard
                        topLevelSection
                        collectionsSection
                        utilitiesSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
            .background(Color(red: 0.05, green: 0.06, blue: 0.08).ignoresSafeArea())
            .navigationTitle("Browse")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .toolbar {
                uploadAndSettingsToolbar
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .task {
                await appState.fetchProfilePhotoIfNeeded()
            }
            .navigationDestination(for: BrowseDestination.self) { destination in
                destinationView(for: destination)
            }
        }
    }

    // MARK: - Subsections

    private var topLevelSection: some View {
        VStack(spacing: 0) {
            destinationRow(
                destination: .allFiles,
                badge: CategoryBadge(icon: "square.grid.2x2", gradient: XTheme.driveGradient),
                title: "All Files",
                count: appState.driveFilesCount
            )
            rowDivider
            actionRow(
                badge: CategoryBadge(icon: "clock", gradient: XTheme.brandGradient),
                title: "Recent",
                count: appState.recentFilesCount
            ) {
                selectedTab = .recents
            }
            rowDivider
            destinationRow(
                destination: .favorites,
                badge: CategoryBadge(icon: "star", gradient: XTheme.favoritesGradient),
                title: "Favorites",
                count: appState.favoritesFilesCount
            )
        }
        .frostedGlassCard(cornerRadius: 16)
    }

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("COLLECTIONS")
            VStack(spacing: 0) {
                destinationRow(
                    destination: .photos,
                    badge: CategoryBadge(icon: "photo.fill", gradient: XTheme.photosGradient),
                    title: "Photos",
                    count: appState.photosCount
                )
                rowDivider
                destinationRow(
                    destination: .videos,
                    badge: CategoryBadge(icon: "play.rectangle", gradient: XTheme.videosGradient),
                    title: "Video",
                    count: appState.videosCount
                )
                rowDivider
                destinationRow(
                    destination: .audio,
                    badge: CategoryBadge(icon: "music.note", gradient: XTheme.audioGradient),
                    title: "Audio",
                    count: appState.audioCount
                )
                rowDivider
                destinationRow(
                    destination: .documents,
                    badge: CategoryBadge(icon: "doc.text", gradient: XTheme.documentsGradient),
                    title: "Documents",
                    count: appState.documentsCount
                )
                rowDivider
                destinationRow(
                    destination: .library,
                    badge: CategoryBadge(icon: "books.vertical", gradient: XTheme.booksGradient),
                    title: "Library",
                    count: appState.libraryCount
                )
            }
            .frostedGlassCard(cornerRadius: 16)
        }
    }

    private var utilitiesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("UTILITIES")
            VStack(spacing: 0) {
                destinationRow(
                    destination: .privateVault,
                    badge: CategoryBadge(icon: "lock.fill", gradient: XTheme.privateFolderGradient),
                    title: "Private Vault",
                    count: appState.vaultFilesCount
                )
                rowDivider
                actionRow(
                    badge: CategoryBadge(icon: "arrow.triangle.swap", gradient: XTheme.sharedGradient),
                    title: "Shared",
                    count: appState.sharedFilesCount
                ) {
                    selectedTab = .shared
                }
                rowDivider
                destinationRow(
                    destination: .transfers,
                    badge: CategoryBadge(icon: "arrow.up.arrow.down", gradient: XTheme.transfersGradient),
                    title: "Transfers",
                    count: appState.isUploading ? 1 : 0,
                    badgeHighlight: appState.isUploading
                )
                rowDivider
                destinationRow(
                    destination: .archive,
                    badge: CategoryBadge(icon: "archivebox", gradient: XTheme.archiveGradient),
                    title: "Archive",
                    count: appState.archiveFilesCount
                )
                rowDivider
                destinationRow(
                    destination: .trash,
                    badge: CategoryBadge(icon: "trash", gradient: XTheme.trashGradient),
                    title: "Recently Deleted",
                    count: appState.trashFilesCount
                )
            }
            .frostedGlassCard(cornerRadius: 16)
        }
    }

    @ToolbarContentBuilder
    private var uploadAndSettingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 12) {
                StandardAddMenu(folderID: "", isPrivate: false)

                BlueEllipsisMenu {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func destinationView(for destination: BrowseDestination) -> some View {
        switch destination {
        case .allFiles:
            FileBrowserView(folderID: "", folderTitle: "All Files")
        case .privateVault:
            PrivateVaultView()
        case .transfers:
            TransfersView()
        case .archive:
            ArchiveView()
        case .trash:
            TrashView()
        case .favorites:
            FavoritesView()
        case .photos:
            PhotosView()
        case .videos:
            VideosView()
        case .audio:
            AudioView()
        case .documents:
            DocumentsView()
        case .library:
            LibraryView()
        }
    }

    // MARK: - Profile Header Card

    private var profileHeaderCard: some View {
        HStack(spacing: 12) {
            ZStack {
                if let photoData = appState.profilePhotoData, let uiImage = UIImage(data: photoData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                } else {
                    Circle()
                        .fill(XTheme.brandGradient)
                        .frame(width: 44, height: 44)
                        .overlay {
                            Text(initials)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                        }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(accountDisplayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(statusSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(8)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frostedGlassCard(cornerRadius: 16)
    }

    private var initials: String {
        let name = accountDisplayName
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private var accountDisplayName: String {
        if let id = appState.identity {
            let full = "\(id.firstName) \(id.lastName)".trimmingCharacters(in: .whitespaces)
            if !full.isEmpty { return full }
            if !id.username.isEmpty { return "@\(id.username)" }
        }
        return "Cascade Vault"
    }

    private var statusSubtitle: String {
        let count = appState.allFiles.filter { !$0.trashed && !$0.isArchived }.count
        let used = XTheme.formatBytes(appState.totalStorageBytes)
        return "\(used) · \(count) \(count == 1 ? "item" : "items")"
    }

    private var searchResults: [FileItem] {
        guard !searchText.isEmpty else { return [] }
        return appState.allFiles.filter {
            !$0.trashed && !$0.isArchived && $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    @ViewBuilder
    private var browseSearchResults: some View {
        if searchResults.isEmpty {
            NoSearchResultsView(query: searchText)
                .padding(.top, 40)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("SEARCH RESULTS (\(searchResults.count))")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.secondary)
                    .tracking(0.5)

                VStack(spacing: 0) {
                    ForEach(searchResults) { file in
                        Button {
                            if file.isFolder {
                                appState.browseNavPath.append(BrowseDestination.allFiles)
                            } else {
                                appState.openFile(file)
                            }
                        } label: {
                            FileRow(file: file)
                        }
                        .buttonStyle(.plain)

                        if file.id != searchResults.last?.id {
                            rowDivider
                        }
                    }
                }
                .frostedGlassCard(cornerRadius: 16)
            }
        }
    }

    // MARK: - Row Helpers

    private func destinationRow(
        destination: BrowseDestination,
        badge: some View,
        title: String,
        count: Int = 0,
        badgeHighlight: Bool = false
    ) -> some View {
        NavigationLink(value: destination) {
            HStack(spacing: 14) {
                badge

                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)

                Spacer()

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(badgeHighlight ? Color.white : Color.white.opacity(0.55))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(badgeHighlight ? XTheme.accent : Color.white.opacity(0.08), in: Capsule())
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.25))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func actionRow(
        badge: some View,
        title: String,
        count: Int = 0,
        badgeHighlight: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                badge

                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)

                Spacer()

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(badgeHighlight ? Color.white : Color.white.opacity(0.55))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(badgeHighlight ? XTheme.accent : Color.white.opacity(0.08), in: Capsule())
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.25))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rowDivider: some View {
        Divider()
            .background(Color.white.opacity(0.06))
            .padding(.leading, 56)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color.white.opacity(0.40))
            .tracking(0.6)
            .padding(.horizontal, 6)
    }
}

// MARK: - Recents View

struct RecentsView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var viewMode: ViewMode = .grid
    @State private var sortBy: SortOption = .date
    @State private var sortAscending = true
    @State private var isSelecting = false
    @State private var selectedFileIDs: Set<String> = []

    enum ViewMode: String, CaseIterable {
        case grid = "Icons"
        case list = "List"
    }

    enum SortOption: String, CaseIterable {
        case date = "Date"
        case name = "Name"
        case size = "Size"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.05, green: 0.06, blue: 0.08).ignoresSafeArea()

                Group {
                    if filteredFiles.isEmpty {
                        if !searchText.isEmpty {
                            NoSearchResultsView(query: searchText)
                        } else {
                            emptyState
                        }
                    } else if viewMode == .grid {
                        gridView
                    } else {
                        listView
                    }
                }
            }
            .navigationTitle("Recents")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .toolbar {
                if isSelecting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(selectedFileIDs.count == filteredFiles.count ? "Deselect All" : "Select All") {
                            if selectedFileIDs.count == filteredFiles.count {
                                selectedFileIDs.removeAll()
                            } else {
                                selectedFileIDs = Set(filteredFiles.map(\.id))
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            isSelecting = false
                            selectedFileIDs.removeAll()
                        }
                        .fontWeight(.semibold)
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 12) {
                            StandardAddMenu(folderID: "", isPrivate: false)

                            BlueEllipsisMenu {
                                Button {
                                    isSelecting = true
                                } label: {
                                    Label("Select", systemImage: "checkmark.circle")
                                }

                                Divider()

                                Button {
                                    viewMode = .grid
                                } label: {
                                    HStack {
                                        Text("Icons")
                                        if viewMode == .grid {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }

                                Button {
                                    viewMode = .list
                                } label: {
                                    HStack {
                                        Text("List")
                                        if viewMode == .list {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }

                                Divider()

                                ForEach(SortOption.allCases, id: \.self) { option in
                                    Button {
                                        if sortBy == option {
                                            sortAscending.toggle()
                                        } else {
                                            sortBy = option
                                            sortAscending = true
                                        }
                                    } label: {
                                        HStack {
                                            Text(option.rawValue)
                                            if sortBy == option {
                                                Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    selectionBottomBar
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Material.ultraThinMaterial, for: .navigationBar)
            .task {
                await appState.syncRecentsFromCloud()
            }
            .refreshable {
                async let f1: () = appState.loadAllFiles()
                async let f2: () = appState.syncRecentsFromCloud()
                _ = await (f1, f2)
            }
        }
    }

    private var selectionBottomBar: some View {
        HStack {
            Button {
                appState.toggleFavorites(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "heart")
                        .font(.system(size: 20))
                    Text("Favorite")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button {
                appState.toggleArchive(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 20))
                    Text("Archive")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button(role: .destructive) {
                appState.trashFiles(selectedFileIDs)
                selectedFileIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.system(size: 20))
                    Text("Delete")
                        .font(.system(size: 10))
                }
                .foregroundStyle(selectedFileIDs.isEmpty ? Color.secondary : Color.red)
            }
            .disabled(selectedFileIDs.isEmpty)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 10)
        .background(Material.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock")
                .font(.system(size: 48))
                .foregroundStyle(XTheme.accent)
            Text("No Recent Files")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("Files you open or add will appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recentFiles: [FileItem] {
        let fileMap = Dictionary(uniqueKeysWithValues: appState.allFiles.filter { !$0.isFolder && !$0.trashed && !$0.isArchived }.map { ($0.id, $0) })
        let ordered = appState.recentFileIDs.compactMap { fileMap[$0] }
        switch sortBy {
        case .date:
            return sortAscending ? ordered : ordered.reversed()
        case .name:
            return ordered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == (sortAscending ? .orderedAscending : .orderedDescending) }
        case .size:
            return ordered.sorted { sortAscending ? ($0.size > $1.size) : ($0.size < $1.size) }
        }
    }

    private var filteredFiles: [FileItem] {
        let files = Array(recentFiles.prefix(40))
        guard !searchText.isEmpty else { return files }
        return files.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var gridView: some View {
        ScrollView {
            VStack(spacing: 0) {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ], spacing: 28) {
                    ForEach(filteredFiles) { file in
                        if isSelecting {
                            FileGridItem(
                                file: file,
                                isSelecting: true,
                                isSelected: selectedFileIDs.contains(file.id)
                            ) {
                                toggleSelection(file.id)
                            }
                        } else {
                            FileGridItem(file: file) {
                                appState.openFile(file)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer(minLength: 40)

                PageItemCountFooter(count: filteredFiles.count, showSyncStatus: false)
                    .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var listView: some View {
        List {
            ForEach(filteredFiles) { file in
                if isSelecting {
                    FileRow(
                        file: file,
                        isSelecting: true,
                        isSelected: selectedFileIDs.contains(file.id)
                    ) {
                        toggleSelection(file.id)
                    }
                } else {
                    FileRow(file: file) {
                        appState.openFile(file)
                    }
                }
            }

            PageItemCountFooter(count: filteredFiles.count, showSyncStatus: false)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
    }

    private func toggleSelection(_ id: String) {
        if selectedFileIDs.contains(id) {
            selectedFileIDs.remove(id)
        } else {
            selectedFileIDs.insert(id)
        }
    }
}

// MARK: - Shared View (Files-app style with banner & menu)

struct SharedView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var showBanner = true
    @State private var viewMode: ViewMode = .grid
    @State private var sortBy: SortOption = .date
    @State private var sortAscending = false
    @State private var isSelecting = false

    enum ViewMode: String, CaseIterable {
        case grid = "Icons"
        case list = "List"
    }

    enum SortOption: String, CaseIterable {
        case date = "Date"
        case name = "Name"
        case kind = "Kind"
        case size = "Size"
    }

    private var activeShares: [ShareRecord] {
        let shares = appState.activeOutgoingShares
        var filtered = shares
        if !searchText.isEmpty {
            filtered = filtered.filter { $0.fileName.localizedCaseInsensitiveContains(searchText) }
        }
        return filtered.sorted { a, b in
            switch sortBy {
            case .date:
                return sortAscending ? a.createdAt < b.createdAt : a.createdAt > b.createdAt
            case .name:
                return sortAscending ? a.fileName < b.fileName : a.fileName > b.fileName
            case .kind:
                return sortAscending ? (!a.isPublic && b.isPublic) : (a.isPublic && !b.isPublic)
            case .size:
                return sortAscending ? a.createdAt < b.createdAt : a.createdAt > b.createdAt
            }
        }
    }

    private var publicShares: [ShareRecord] { activeShares.filter { $0.isPublic } }
    private var privateShares: [ShareRecord] { activeShares.filter { !$0.isPublic } }

    private let gridColumns = [
        GridItem(.adaptive(minimum: 104, maximum: 120), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.05, green: 0.06, blue: 0.08).ignoresSafeArea()

                Group {
                    if activeShares.isEmpty {
                        ScrollView {
                            VStack(spacing: 24) {
                                if showBanner {
                                    familyBanner
                                }

                                if !searchText.isEmpty {
                                    NoSearchResultsView(query: searchText)
                                } else {
                                    emptyState
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                        }
                    } else if viewMode == .grid {
                        gridView
                    } else {
                        listView
                    }
                }
            }
            .navigationTitle("Shared")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        StandardAddMenu(folderID: "", isPrivate: false)

                        BlueEllipsisMenu {
                            Section {
                                Button {
                                    isSelecting = true
                                } label: {
                                    Label("Select", systemImage: "checkmark.circle")
                                }
                            }

                            Section {
                                Button {
                                    viewMode = .grid
                                } label: {
                                    HStack {
                                        Text("Icons")
                                        if viewMode == .grid {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }

                                Button {
                                    viewMode = .list
                                } label: {
                                    HStack {
                                        Text("List")
                                        if viewMode == .list {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }

                            Section {
                                ForEach(SortOption.allCases, id: \.self) { option in
                                    Button {
                                        if sortBy == option {
                                            sortAscending.toggle()
                                        } else {
                                            sortBy = option
                                            sortAscending = (option == .name)
                                        }
                                    } label: {
                                        HStack {
                                            Text(option.rawValue)
                                            if sortBy == option {
                                                Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .task {
                await appState.loadShares()
            }
            .refreshable {
                await appState.loadShares()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.person.crop")
                .font(.system(size: 48))
                .foregroundStyle(XTheme.accent)
            Text("No Shared Files")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("Files and folders shared with you or shared by you will appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, showBanner ? 20 : 60)
    }

    private var gridView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if showBanner {
                    familyBanner
                        .padding(.horizontal, 16)
                }

                if !publicShares.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("PUBLIC SHARES (\(publicShares.count))")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.40))
                            .tracking(0.6)
                            .padding(.horizontal, 16)

                        LazyVGrid(columns: gridColumns, spacing: 20) {
                            ForEach(publicShares) { share in
                                ShareGridCard(share: share)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                if !privateShares.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("PRIVATE SHARES (\(privateShares.count))")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.40))
                            .tracking(0.6)
                            .padding(.horizontal, 16)

                        LazyVGrid(columns: gridColumns, spacing: 20) {
                            ForEach(privateShares) { share in
                                ShareGridCard(share: share)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
    }

    private var listView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if showBanner {
                    familyBanner
                }

                if !publicShares.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PUBLIC SHARES (\(publicShares.count))")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.40))
                            .tracking(0.6)
                            .padding(.horizontal, 4)

                        VStack(spacing: 8) {
                            ForEach(publicShares) { share in
                                ShareListRow(share: share)
                            }
                        }
                    }
                }

                if !privateShares.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PRIVATE SHARES (\(privateShares.count))")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.40))
                            .tracking(0.6)
                            .padding(.horizontal, 4)

                        VStack(spacing: 8) {
                            ForEach(privateShares) { share in
                                ShareListRow(share: share)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
    }

    private var familyBanner: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.blue.gradient)
                    .frame(width: 44, height: 44)
                Image(systemName: "person.2.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Share Files with Anyone")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Long-press any file in your drive and choose Share to generate a secure link.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))

                Button {
                    appState.showImportShareSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "link.badge.plus")
                        Text("Add from Share Link")
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(XTheme.accent)
                    .padding(.top, 2)
                }
            }

            Spacer()

            Button {
                withAnimation { showBanner = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.bold())
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(6)
                    .background(Color.white.opacity(0.1), in: Circle())
            }
        }
        .padding(14)
        .frostedGlassCard(cornerRadius: 16)
    }
}

// MARK: - Share Grid Card

struct ShareGridCard: View {
    let share: ShareRecord
    @Environment(AppState.self) private var appState

    private var shareLinkURL: String {
        share.linkBlob ?? share.inviteLink
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(share.isPublic ? Color.green.opacity(0.12) : Color.orange.opacity(0.12))

                    Image(systemName: share.isPublic ? "globe" : "lock.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(share.isPublic ? Color.green : Color.orange)
                }
                .frame(height: 94)
                .frame(maxWidth: .infinity)

                HStack(spacing: 3) {
                    Image(systemName: share.isPublic ? "globe" : "lock.fill")
                        .font(.system(size: 9))
                    Text(share.isPublic ? "Public" : "Private")
                        .font(.system(size: 9, weight: .bold))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(share.isPublic ? Color.green.opacity(0.85) : Color.orange.opacity(0.85), in: Capsule())
                .foregroundStyle(.white)
                .padding(6)
            }

            VStack(spacing: 2) {
                Text(share.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)

                Text(share.isPublic ? "Never expires" : "Expires \(share.expiry.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(10)
        .frostedGlassCard(cornerRadius: 14)
        .contextMenu {
            Button {
                UIPasteboard.general.string = shareLinkURL
            } label: {
                Label("Copy Link", systemImage: "doc.on.doc")
            }

            Button {
                UIPasteboard.general.string = shareLinkURL
                appState.shareActivityItems = [URL(string: shareLinkURL) ?? shareLinkURL]
            } label: {
                Label("Share Link...", systemImage: "square.and.arrow.up")
            }

            Divider()

            Button(role: .destructive) {
                appState.cancelShare(share)
            } label: {
                Label("Revoke Share", systemImage: "xmark.circle")
            }
        }
    }
}

// MARK: - Share List Row

struct ShareListRow: View {
    let share: ShareRecord
    @Environment(AppState.self) private var appState

    private var shareLinkURL: String {
        share.linkBlob ?? share.inviteLink
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(share.isPublic ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                Image(systemName: share.isPublic ? "globe" : "lock.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(share.isPublic ? Color.green : Color.orange)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(share.fileName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text(share.isPublic ? "Public Share" : "Private Share")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(share.isPublic ? Color.green : Color.orange)

                    Text("•")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))

                    Text(share.isPublic ? "Never expires" : "Expires \(share.expiry.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }

            Spacer()

            Button {
                UIPasteboard.general.string = shareLinkURL
                appState.shareActivityItems = [URL(string: shareLinkURL) ?? shareLinkURL]
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15))
                    .foregroundStyle(XTheme.accent)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frostedGlassCard(cornerRadius: 14)
        .contextMenu {
            Button {
                UIPasteboard.general.string = shareLinkURL
            } label: {
                Label("Copy Link", systemImage: "doc.on.doc")
            }

            Button {
                UIPasteboard.general.string = shareLinkURL
                appState.shareActivityItems = [URL(string: shareLinkURL) ?? shareLinkURL]
            } label: {
                Label("Share Link...", systemImage: "square.and.arrow.up")
            }

            Divider()

            Button(role: .destructive) {
                appState.cancelShare(share)
            } label: {
                Label("Revoke Share", systemImage: "xmark.circle")
            }
        }
    }
}

// MARK: - Share File Modal Sheet

struct ShareFileSheet: View {
    let file: FileItem
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var isPublic: Bool = false
    @State private var usePassword: Bool = false
    @State private var passwordText: String = ""
    @State private var isGenerating: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.blue.opacity(0.12))
                            Image(systemName: file.isFolder ? "folder.fill" : "doc.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(XTheme.accent)
                        }
                        .frame(width: 40, height: 40)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name)
                                .font(.headline)
                                .lineLimit(1)
                            if let size = file.formattedSize {
                                Text(size)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Share Type") {
                    Picker("Type", selection: $isPublic) {
                        Text("Private (Expiring)").tag(false)
                        Text("Public (Permanent)").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if isPublic {
                        Text("Creates a permanent link in the persistent public channel. Does not expire.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Takes a dedicated channel from the private pool. Expires in 24 hours.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Security") {
                    Toggle("Password Protect Link", isOn: $usePassword)
                    if usePassword {
                        SecureField("Enter Password", text: $passwordText)
                    }
                }

                if let err = errorMessage {
                    Section {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        createShare()
                    } label: {
                        HStack {
                            Spacer()
                            if isGenerating {
                                ProgressView()
                                    .padding(.trailing, 6)
                            }
                            Text(isGenerating ? "Creating Share Link..." : "Create & Share Link")
                                .font(.headline)
                                .foregroundStyle(isGenerating ? Color.secondary : Color.blue)
                            Spacer()
                        }
                    }
                    .disabled(isGenerating || (usePassword && passwordText.isEmpty))
                }
            }
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func createShare() {
        isGenerating = true
        errorMessage = nil

        Task {
            do {
                let link = try await appState.shareFile(
                    file,
                    isPublic: isPublic,
                    password: usePassword && !passwordText.isEmpty ? passwordText : nil
                )
                await MainActor.run {
                    self.isGenerating = false
                    self.dismiss()
                    UIPasteboard.general.string = link
                    appState.shareActivityItems = [URL(string: link) ?? link]
                }
            } catch {
                await MainActor.run {
                    self.isGenerating = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Move Destination Picker Sheet

struct MoveDestinationPickerSheet: View {
    let fileIDs: Set<String>
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var currentFolderID: String? = nil
    @State private var folderStack: [(id: String?, name: String)] = [(nil, "Cascade Drive")]

    private var currentFolders: [FileItem] {
        let parentMatch = (currentFolderID?.isEmpty == true) ? nil : currentFolderID
        return appState.allFiles.filter {
            $0.isFolder &&
            !$0.trashed &&
            !$0.isArchived &&
            !fileIDs.contains($0.id) &&
            (($0.parentID == nil || $0.parentID?.isEmpty == true) ? (parentMatch == nil) : ($0.parentID == parentMatch))
        }
    }

    private var currentFolderName: String {
        folderStack.last?.name ?? "Cascade Drive"
    }

    var body: some View {
        NavigationStack {
            List {
                if folderStack.count > 1 {
                    Button {
                        _ = folderStack.popLast()
                        currentFolderID = folderStack.last?.id ?? nil
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.backward.circle.fill")
                                .font(.title3)
                                .foregroundStyle(XTheme.accent)
                            Text("Back to \(folderStack[folderStack.count - 2].name)")
                                .font(.body)
                                .foregroundStyle(XTheme.accent)
                        }
                    }
                }

                Section("Folders in \(currentFolderName)") {
                    if currentFolders.isEmpty {
                        Text("No subfolders")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(currentFolders) { folder in
                            Button {
                                folderStack.append((folder.id, folder.name))
                                currentFolderID = folder.id
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder.fill")
                                        .font(.title3)
                                        .foregroundStyle(XTheme.accent)
                                    Text(folder.name)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Move to \(currentFolderName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Move Here") {
                        let target = (currentFolderID?.isEmpty == true) ? nil : currentFolderID
                        appState.moveFiles(fileIDs, to: target)
                        dismiss()
                    }
                    .font(.headline)
                    .foregroundStyle(XTheme.accent)
                }
            }
        }
    }
}

// MARK: - Sheet Wrappers

struct MoveSheetWrapper: Identifiable {
    let id = UUID()
    let ids: Set<String>
}

struct ActivityItemsWrapper: Identifiable {
    let id = UUID()
    let items: [Any]
}

// MARK: - Photos View

struct PhotosView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var viewportHeight: CGFloat = 0
    @State private var isSelecting = false
    @State private var selectedFileIDs: Set<String> = []

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.08).ignoresSafeArea()

            Group {
                if filteredPhotos.isEmpty {
                    if !searchText.isEmpty {
                        NoSearchResultsView(query: searchText)
                    } else {
                        emptyState
                    }
                } else {
                    gridView
                }
            }
        }
        .navigationTitle("Photos")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectedFileIDs.count == filteredPhotos.count ? "Deselect All" : "Select All") {
                        if selectedFileIDs.count == filteredPhotos.count {
                            selectedFileIDs.removeAll()
                        } else {
                            selectedFileIDs = Set(filteredPhotos.map(\.id))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isSelecting = false
                        selectedFileIDs.removeAll()
                    }
                    .fontWeight(.semibold)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        StandardAddMenu(folderID: "", isPrivate: false)

                        BlueEllipsisMenu {
                            Button {
                                isSelecting = true
                            } label: {
                                Label("Select", systemImage: "checkmark.circle")
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBottomBar
            }
        }
    }

    private var selectionBottomBar: some View {
        HStack {
            Button {
                appState.toggleFavorites(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "heart")
                        .font(.system(size: 20))
                    Text("Favorite")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button {
                appState.toggleArchive(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 20))
                    Text("Archive")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button(role: .destructive) {
                appState.trashFiles(selectedFileIDs)
                selectedFileIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.system(size: 20))
                    Text("Delete")
                        .font(.system(size: 10))
                }
                .foregroundStyle(selectedFileIDs.isEmpty ? Color.secondary : Color.red)
            }
            .disabled(selectedFileIDs.isEmpty)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 10)
        .background(Material.bar)
    }

    private var photoFiles: [FileItem] {
        appState.allFiles.filter { $0.isImage && !$0.trashed && !$0.isArchived }
    }

    private var filteredPhotos: [FileItem] {
        guard !searchText.isEmpty else { return photoFiles }
        return photoFiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo")
                .font(.system(size: 48))
                .foregroundStyle(XTheme.accent)
            Text("No Photos")
                .font(.title2.bold())
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var gridView: some View {
        ScrollView {
            VStack(spacing: 0) {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ], spacing: 28) {
                    ForEach(filteredPhotos) { file in
                        if isSelecting {
                            FileGridItem(
                                file: file,
                                isSelecting: true,
                                isSelected: selectedFileIDs.contains(file.id)
                            ) {
                                toggleSelection(file.id)
                            }
                        } else {
                            FileGridItem(file: file) {
                                appState.openFile(file)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer(minLength: 40)

                PageItemCountFooter(count: filteredPhotos.count, noun: "photo")
                    .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: max(0, viewportHeight - 16), alignment: .top)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewportHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, newHeight in viewportHeight = newHeight }
            }
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedFileIDs.contains(id) {
            selectedFileIDs.remove(id)
        } else {
            selectedFileIDs.insert(id)
        }
    }
}

// MARK: - Videos View

struct VideosView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var viewportHeight: CGFloat = 0
    @State private var isSelecting = false
    @State private var selectedFileIDs: Set<String> = []

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.08).ignoresSafeArea()

            Group {
                if filteredVideos.isEmpty {
                    if !searchText.isEmpty {
                        NoSearchResultsView(query: searchText)
                    } else {
                        emptyState
                    }
                } else {
                    gridView
                }
            }
        }
        .navigationTitle("Videos")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectedFileIDs.count == filteredVideos.count ? "Deselect All" : "Select All") {
                        if selectedFileIDs.count == filteredVideos.count {
                            selectedFileIDs.removeAll()
                        } else {
                            selectedFileIDs = Set(filteredVideos.map(\.id))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isSelecting = false
                        selectedFileIDs.removeAll()
                    }
                    .fontWeight(.semibold)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        StandardAddMenu(folderID: "", isPrivate: false)

                        BlueEllipsisMenu {
                            Button {
                                isSelecting = true
                            } label: {
                                Label("Select", systemImage: "checkmark.circle")
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBottomBar
            }
        }
    }

    private var selectionBottomBar: some View {
        HStack {
            Button {
                appState.toggleFavorites(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "heart")
                        .font(.system(size: 20))
                    Text("Favorite")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button {
                appState.toggleArchive(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 20))
                    Text("Archive")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button(role: .destructive) {
                appState.trashFiles(selectedFileIDs)
                selectedFileIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.system(size: 20))
                    Text("Delete")
                        .font(.system(size: 10))
                }
                .foregroundStyle(selectedFileIDs.isEmpty ? Color.secondary : Color.red)
            }
            .disabled(selectedFileIDs.isEmpty)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 10)
        .background(Material.bar)
    }

    private var videoFiles: [FileItem] {
        appState.allFiles.filter { $0.isVideo && !$0.trashed && !$0.isArchived }
    }

    private var filteredVideos: [FileItem] {
        guard !searchText.isEmpty else { return videoFiles }
        return videoFiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film")
                .font(.system(size: 48))
                .foregroundStyle(XTheme.accent)
            Text("No Videos")
                .font(.title2.bold())
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var gridView: some View {
        ScrollView {
            VStack(spacing: 0) {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ], spacing: 28) {
                    ForEach(filteredVideos) { file in
                        if isSelecting {
                            FileGridItem(
                                file: file,
                                isSelecting: true,
                                isSelected: selectedFileIDs.contains(file.id)
                            ) {
                                toggleSelection(file.id)
                            }
                        } else {
                            FileGridItem(file: file) {
                                appState.openFile(file)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer(minLength: 40)

                PageItemCountFooter(count: filteredVideos.count, noun: "video")
                    .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: max(0, viewportHeight - 16), alignment: .top)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewportHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, newHeight in viewportHeight = newHeight }
            }
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedFileIDs.contains(id) {
            selectedFileIDs.remove(id)
        } else {
            selectedFileIDs.insert(id)
        }
    }
}

// MARK: - Audio View

struct AudioView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var viewMode: ViewMode = .grid
    @State private var viewportHeight: CGFloat = 0
    @State private var isSelecting = false
    @State private var selectedFileIDs: Set<String> = []

    enum ViewMode: String {
        case grid = "Icons"
        case list = "List"
    }

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.08).ignoresSafeArea()

            Group {
                if filteredAudio.isEmpty {
                    if !searchText.isEmpty {
                        NoSearchResultsView(query: searchText)
                    } else {
                        emptyState
                    }
                } else if viewMode == .grid {
                    gridView
                } else {
                    listView
                }
            }
        }
        .navigationTitle("Audio")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectedFileIDs.count == filteredAudio.count ? "Deselect All" : "Select All") {
                        if selectedFileIDs.count == filteredAudio.count {
                            selectedFileIDs.removeAll()
                        } else {
                            selectedFileIDs = Set(filteredAudio.map(\.id))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isSelecting = false
                        selectedFileIDs.removeAll()
                    }
                    .fontWeight(.semibold)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        StandardAddMenu(folderID: "", isPrivate: false)

                        BlueEllipsisMenu {
                            Button {
                                isSelecting = true
                            } label: {
                                Label("Select", systemImage: "checkmark.circle")
                            }
                            Divider()
                            Button { viewMode = .grid } label: {
                                HStack {
                                    Text("Icons")
                                    if viewMode == .grid { Image(systemName: "checkmark") }
                                }
                            }
                            Button { viewMode = .list } label: {
                                HStack {
                                    Text("List")
                                    if viewMode == .list { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBottomBar
            }
        }
    }

    private var selectionBottomBar: some View {
        HStack {
            Button {
                appState.toggleFavorites(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "heart")
                        .font(.system(size: 20))
                    Text("Favorite")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button {
                appState.toggleArchive(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 20))
                    Text("Archive")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button(role: .destructive) {
                appState.trashFiles(selectedFileIDs)
                selectedFileIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.system(size: 20))
                    Text("Delete")
                        .font(.system(size: 10))
                }
                .foregroundStyle(selectedFileIDs.isEmpty ? Color.secondary : Color.red)
            }
            .disabled(selectedFileIDs.isEmpty)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 10)
        .background(Material.bar)
    }

    private var audioFiles: [FileItem] {
        appState.allFiles.filter { $0.isAudio && !$0.trashed && !$0.isArchived }
    }

    private var filteredAudio: [FileItem] {
        guard !searchText.isEmpty else { return audioFiles }
        return audioFiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: 48))
                .foregroundStyle(XTheme.accent)
            Text("No Audio Files")
                .font(.title2.bold())
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var gridView: some View {
        ScrollView {
            VStack(spacing: 0) {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ], spacing: 28) {
                    ForEach(filteredAudio) { file in
                        if isSelecting {
                            FileGridItem(
                                file: file,
                                isSelecting: true,
                                isSelected: selectedFileIDs.contains(file.id)
                            ) {
                                toggleSelection(file.id)
                            }
                        } else {
                            FileGridItem(file: file) {
                                appState.openFile(file)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer(minLength: 40)

                PageItemCountFooter(count: filteredAudio.count)
                    .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: max(0, viewportHeight - 16), alignment: .top)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewportHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, newHeight in viewportHeight = newHeight }
            }
        }
    }

    private var listView: some View {
        List {
            ForEach(filteredAudio) { file in
                if isSelecting {
                    FileRow(
                        file: file,
                        isSelecting: true,
                        isSelected: selectedFileIDs.contains(file.id)
                    ) {
                        toggleSelection(file.id)
                    }
                } else {
                    FileRow(file: file) {
                        appState.openFile(file)
                    }
                }
            }

            PageItemCountFooter(count: filteredAudio.count)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
    }

    private func toggleSelection(_ id: String) {
        if selectedFileIDs.contains(id) {
            selectedFileIDs.remove(id)
        } else {
            selectedFileIDs.insert(id)
        }
    }
}

// MARK: - Documents View

struct DocumentsView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var viewMode: ViewMode = .grid
    @State private var viewportHeight: CGFloat = 0
    @State private var isSelecting = false
    @State private var selectedFileIDs: Set<String> = []

    enum ViewMode: String {
        case grid = "Icons"
        case list = "List"
    }

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.08).ignoresSafeArea()

            Group {
                if filteredDocs.isEmpty {
                    if !searchText.isEmpty {
                        NoSearchResultsView(query: searchText)
                    } else {
                        emptyState
                    }
                } else if viewMode == .grid {
                    gridView
                } else {
                    listView
                }
            }
        }
        .navigationTitle("Documents")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectedFileIDs.count == filteredDocs.count ? "Deselect All" : "Select All") {
                        if selectedFileIDs.count == filteredDocs.count {
                            selectedFileIDs.removeAll()
                        } else {
                            selectedFileIDs = Set(filteredDocs.map(\.id))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isSelecting = false
                        selectedFileIDs.removeAll()
                    }
                    .fontWeight(.semibold)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        StandardAddMenu(folderID: "", isPrivate: false)

                        BlueEllipsisMenu {
                            Button {
                                isSelecting = true
                            } label: {
                                Label("Select", systemImage: "checkmark.circle")
                            }
                            Divider()
                            Button { viewMode = .grid } label: {
                                HStack {
                                    Text("Icons")
                                    if viewMode == .grid { Image(systemName: "checkmark") }
                                }
                            }
                            Button { viewMode = .list } label: {
                                HStack {
                                    Text("List")
                                    if viewMode == .list { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBottomBar
            }
        }
    }

    private var selectionBottomBar: some View {
        HStack {
            Button {
                appState.toggleFavorites(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "heart")
                        .font(.system(size: 20))
                    Text("Favorite")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button {
                appState.toggleArchive(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 20))
                    Text("Archive")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button(role: .destructive) {
                appState.trashFiles(selectedFileIDs)
                selectedFileIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.system(size: 20))
                    Text("Delete")
                        .font(.system(size: 10))
                }
                .foregroundStyle(selectedFileIDs.isEmpty ? Color.secondary : Color.red)
            }
            .disabled(selectedFileIDs.isEmpty)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 10)
        .background(Material.bar)
    }

    private var documentFiles: [FileItem] {
        appState.allFiles.filter { $0.isDocument && !$0.trashed && !$0.isArchived }
    }

    private var filteredDocs: [FileItem] {
        guard !searchText.isEmpty else { return documentFiles }
        return documentFiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(XTheme.accent)
            Text("No Documents")
                .font(.title2.bold())
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var gridView: some View {
        ScrollView {
            VStack(spacing: 0) {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ], spacing: 28) {
                    ForEach(filteredDocs) { file in
                        if isSelecting {
                            FileGridItem(
                                file: file,
                                isSelecting: true,
                                isSelected: selectedFileIDs.contains(file.id)
                            ) {
                                toggleSelection(file.id)
                            }
                        } else {
                            FileGridItem(file: file) {
                                appState.openFile(file)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer(minLength: 40)

                PageItemCountFooter(count: filteredDocs.count)
                    .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: max(0, viewportHeight - 16), alignment: .top)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewportHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, newHeight in viewportHeight = newHeight }
            }
        }
    }

    private var listView: some View {
        List {
            ForEach(filteredDocs) { file in
                if isSelecting {
                    FileRow(
                        file: file,
                        isSelecting: true,
                        isSelected: selectedFileIDs.contains(file.id)
                    ) {
                        toggleSelection(file.id)
                    }
                } else {
                    FileRow(file: file) {
                        appState.openFile(file)
                    }
                }
            }

            PageItemCountFooter(count: filteredDocs.count)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
    }

    private func toggleSelection(_ id: String) {
        if selectedFileIDs.contains(id) {
            selectedFileIDs.remove(id)
        } else {
            selectedFileIDs.insert(id)
        }
    }
}

// MARK: - Library View

struct LibraryView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var viewMode: ViewMode = .grid
    @State private var viewportHeight: CGFloat = 0
    @State private var isSelecting = false
    @State private var selectedFileIDs: Set<String> = []

    enum ViewMode: String {
        case grid = "Icons"
        case list = "List"
    }

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.08).ignoresSafeArea()

            Group {
                if filteredBooks.isEmpty {
                    if !searchText.isEmpty {
                        NoSearchResultsView(query: searchText)
                    } else {
                        emptyState
                    }
                } else if viewMode == .grid {
                    gridView
                } else {
                    listView
                }
            }
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectedFileIDs.count == filteredBooks.count ? "Deselect All" : "Select All") {
                        if selectedFileIDs.count == filteredBooks.count {
                            selectedFileIDs.removeAll()
                        } else {
                            selectedFileIDs = Set(filteredBooks.map(\.id))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isSelecting = false
                        selectedFileIDs.removeAll()
                    }
                    .fontWeight(.semibold)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        StandardAddMenu(folderID: "", isPrivate: false)

                        BlueEllipsisMenu {
                            Button {
                                isSelecting = true
                            } label: {
                                Label("Select", systemImage: "checkmark.circle")
                            }
                            Divider()
                            Button { viewMode = .grid } label: {
                                HStack {
                                    Text("Icons")
                                    if viewMode == .grid { Image(systemName: "checkmark") }
                                }
                            }
                            Button { viewMode = .list } label: {
                                HStack {
                                    Text("List")
                                    if viewMode == .list { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBottomBar
            }
        }
    }

    private var selectionBottomBar: some View {
        HStack {
            Button {
                appState.toggleFavorites(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "heart")
                        .font(.system(size: 20))
                    Text("Favorite")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button {
                appState.toggleArchive(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 20))
                    Text("Archive")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button(role: .destructive) {
                appState.trashFiles(selectedFileIDs)
                selectedFileIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.system(size: 20))
                    Text("Delete")
                        .font(.system(size: 10))
                }
                .foregroundStyle(selectedFileIDs.isEmpty ? Color.secondary : Color.red)
            }
            .disabled(selectedFileIDs.isEmpty)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 10)
        .background(Material.bar)
    }

    private var libraryFiles: [FileItem] {
        appState.allFiles.filter { !$0.isFolder && !$0.trashed && !$0.isArchived && ($0.isInLibrary || $0.isBook || $0.isBookFile) }
    }

    private var filteredBooks: [FileItem] {
        guard !searchText.isEmpty else { return libraryFiles }
        return libraryFiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 48))
                .foregroundStyle(XTheme.accent)
            Text("No Books in Library")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("EPUB, PDF, MOBI, and other books will appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var gridView: some View {
        ScrollView {
            VStack(spacing: 0) {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ], spacing: 28) {
                    ForEach(filteredBooks) { file in
                        if isSelecting {
                            FileGridItem(
                                file: file,
                                isSelecting: true,
                                isSelected: selectedFileIDs.contains(file.id)
                            ) {
                                toggleSelection(file.id)
                            }
                        } else {
                            FileGridItem(file: file) {
                                appState.openFile(file)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer(minLength: 40)

                PageItemCountFooter(count: filteredBooks.count, noun: "book")
                    .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: max(0, viewportHeight - 16), alignment: .top)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewportHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, newHeight in viewportHeight = newHeight }
            }
        }
    }

    private var listView: some View {
        List {
            ForEach(filteredBooks) { file in
                if isSelecting {
                    FileRow(
                        file: file,
                        isSelecting: true,
                        isSelected: selectedFileIDs.contains(file.id)
                    ) {
                        toggleSelection(file.id)
                    }
                } else {
                    FileRow(file: file) {
                        appState.openFile(file)
                    }
                }
            }

            PageItemCountFooter(count: filteredBooks.count, noun: "book")
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
    }

    private func toggleSelection(_ id: String) {
        if selectedFileIDs.contains(id) {
            selectedFileIDs.remove(id)
        } else {
            selectedFileIDs.insert(id)
        }
    }
}

// MARK: - Vault PIN Screen

struct VaultPINView: View {
    @Environment(AppState.self) private var appState
    var onUnlocked: (() -> Void)? = nil

    @State private var pin: String = ""
    @State private var errorMessage: String? = nil
    @State private var shake: Bool = false
    @State private var isProcessing: Bool = false

    var isRecovery: Bool {
        KeychainStore.loadVaultPINHash() == nil && appState.hasRecoveryBlob
    }

    var isCreate: Bool {
        KeychainStore.loadVaultPINHash() == nil && !appState.hasRecoveryBlob
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: isRecovery ? "key.fill" : "lock.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(XTheme.accent)
            }

            // Title & Subtitle
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.bold())
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                        .padding(.top, 4)
                }
            }

            // 4-dot indicator
            HStack(spacing: 20) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(index < pin.count ? Color.blue : Color(.tertiarySystemFill))
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .stroke(index < pin.count ? Color.blue : Color(.separator), lineWidth: 1.5)
                        )
                }
            }
            .padding(.vertical, 12)
            .offset(x: shake ? -10 : 0)
            .animation(shake ? .default.repeatCount(4, autoreverses: true).speed(4) : .default, value: shake)

            // Keypad
            VStack(spacing: 16) {
                ForEach(0..<3) { row in
                    HStack(spacing: 32) {
                        ForEach(1...3, id: \.self) { col in
                            let digit = row * 3 + col
                            keypadButton(title: "\(digit)") { appendDigit("\(digit)") }
                        }
                    }
                }
                HStack(spacing: 32) {
                    if BiometricUnlock.isAvailable() && !isCreate {
                        Button {
                            Task {
                                if await appState.unlockWithBiometrics() {
                                    onUnlocked?()
                                } else {
                                    errorMessage = "\(BiometricUnlock.biometryName) failed — enter your PIN"
                                }
                            }
                        } label: {
                            Image(systemName: BiometricUnlock.biometryName == "Face ID" ? "faceid" : "touchid")
                                .font(.system(size: 28))
                                .frame(width: 72, height: 72)
                                .foregroundStyle(XTheme.accent)
                        }
                    } else {
                        Spacer().frame(width: 72, height: 72)
                    }

                    keypadButton(title: "0") { appendDigit("0") }

                    Button {
                        if !pin.isEmpty {
                            pin.removeLast()
                            errorMessage = nil
                        }
                    } label: {
                        Image(systemName: "delete.left.fill")
                            .font(.system(size: 22))
                            .frame(width: 72, height: 72)
                            .foregroundStyle(.primary)
                    }
                }
            }
            .disabled(isProcessing)

            Spacer()
        }
        .padding(.horizontal, 24)
        .task {
            if BiometricUnlock.isEligible(hasPINHash: KeychainStore.loadVaultPINHash() != nil) {
                if await appState.unlockWithBiometrics() {
                    onUnlocked?()
                }
            }
        }
    }

    private var title: String {
        if isRecovery { return "Enter Vault PIN" }
        if isCreate { return "Create Vault PIN" }
        return "Unlock Vault"
    }

    private var subtitle: String {
        if isRecovery {
            return "Enter the 4-digit PIN you set on your Mac to unlock and decrypt your files."
        }
        if isCreate {
            return "Choose a 4-digit PIN to secure your files and enable recovery on other devices."
        }
        return "Enter your 4-digit PIN to decrypt your files."
    }

    private func keypadButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.title.bold())
                .frame(width: 72, height: 72)
                .background(Circle().fill(Color(.secondarySystemFill)))
                .foregroundStyle(.primary)
        }
    }

    private func appendDigit(_ digit: String) {
        guard pin.count < 4 else { return }
        pin.append(digit)
        errorMessage = nil
        if pin.count == 4 {
            isProcessing = true
            let submitted = pin
            Task {
                let success = await appState.unlockVault(pin: submitted)
                isProcessing = false
                if success {
                    onUnlocked?()
                } else {
                    errorMessage = "Incorrect PIN. Please try again."
                    triggerShake()
                    pin = ""
                }
            }
        }
    }

    private func triggerShake() {
        shake = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            shake = false
        }
    }
}

// MARK: - Private Vault View

struct PrivateVaultView: View {
    @Environment(AppState.self) private var appState
    @State private var isUnlocked = false

    var body: some View {
        Group {
            if isUnlocked {
                FileBrowserView(folderID: "", folderTitle: "Private Vault", filterPrivate: true)
            } else {
                VaultPINView {
                    isUnlocked = true
                    appState.isVaultLocked = false
                }
            }
        }
        .navigationTitle("Private Vault")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            isUnlocked = false
            appState.isVaultLocked = true
        }
    }
}

// MARK: - Favorites View

struct FavoritesView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var viewMode: ViewMode = .grid
    @State private var viewportHeight: CGFloat = 0
    @State private var isSelecting = false
    @State private var selectedFileIDs: Set<String> = []

    enum ViewMode: String {
        case grid = "Icons"
        case list = "List"
    }

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.08).ignoresSafeArea()

            Group {
                if filteredFavorites.isEmpty {
                    if !searchText.isEmpty {
                        NoSearchResultsView(query: searchText)
                    } else {
                        emptyState
                    }
                } else if viewMode == .grid {
                    gridView
                } else {
                    listView
                }
            }
        }
        .navigationTitle("Favorites")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectedFileIDs.count == filteredFavorites.count ? "Deselect All" : "Select All") {
                        if selectedFileIDs.count == filteredFavorites.count {
                            selectedFileIDs.removeAll()
                        } else {
                            selectedFileIDs = Set(filteredFavorites.map(\.id))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isSelecting = false
                        selectedFileIDs.removeAll()
                    }
                    .fontWeight(.semibold)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        StandardAddMenu(folderID: "", isPrivate: false)

                        BlueEllipsisMenu {
                            Button {
                                isSelecting = true
                            } label: {
                                Label("Select", systemImage: "checkmark.circle")
                            }
                            Divider()
                            Button { viewMode = .grid } label: {
                                HStack {
                                    Text("Icons")
                                    if viewMode == .grid { Image(systemName: "checkmark") }
                                }
                            }
                            Button { viewMode = .list } label: {
                                HStack {
                                    Text("List")
                                    if viewMode == .list { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBottomBar
            }
        }
    }

    private var selectionBottomBar: some View {
        HStack {
            Button {
                appState.toggleFavorites(selectedFileIDs)
                selectedFileIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "heart.slash")
                        .font(.system(size: 20))
                    Text("Unfavorite")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button {
                appState.toggleArchive(selectedFileIDs)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 20))
                    Text("Archive")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button(role: .destructive) {
                appState.trashFiles(selectedFileIDs)
                selectedFileIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.system(size: 20))
                    Text("Delete")
                        .font(.system(size: 10))
                }
                .foregroundStyle(selectedFileIDs.isEmpty ? Color.secondary : Color.red)
            }
            .disabled(selectedFileIDs.isEmpty)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 10)
        .background(Material.bar)
    }

    private var favoriteFiles: [FileItem] {
        appState.allFiles.filter { $0.isFavorite && !$0.trashed }
    }

    private var filteredFavorites: [FileItem] {
        guard !searchText.isEmpty else { return favoriteFiles }
        return favoriteFiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "star")
                .font(.system(size: 48))
                .foregroundStyle(XTheme.accent)
            Text("No Favorites")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("Mark files as favorites to see them here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var gridView: some View {
        ScrollView {
            VStack(spacing: 0) {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ], spacing: 28) {
                    ForEach(filteredFavorites) { file in
                        if isSelecting {
                            FileGridItem(
                                file: file,
                                isSelecting: true,
                                isSelected: selectedFileIDs.contains(file.id)
                            ) {
                                toggleSelection(file.id)
                            }
                        } else {
                            FileGridItem(file: file) {
                                appState.openFile(file)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer(minLength: 40)

                PageItemCountFooter(count: filteredFavorites.count)
                    .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: max(0, viewportHeight - 16), alignment: .top)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewportHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, newHeight in viewportHeight = newHeight }
            }
        }
    }

    private var listView: some View {
        List {
            ForEach(filteredFavorites) { file in
                if isSelecting {
                    FileRow(
                        file: file,
                        isSelecting: true,
                        isSelected: selectedFileIDs.contains(file.id)
                    ) {
                        toggleSelection(file.id)
                    }
                } else {
                    FileRow(file: file) {
                        appState.openFile(file)
                    }
                }
            }

            PageItemCountFooter(count: filteredFavorites.count)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
    }

    private func toggleSelection(_ id: String) {
        if selectedFileIDs.contains(id) {
            selectedFileIDs.remove(id)
        } else {
            selectedFileIDs.insert(id)
        }
    }
}

// MARK: - Transfers View

struct TransfersView: View {
    @Environment(AppState.self) private var appState
    private var center: TransferCenter { TransferCenter.shared }
    @State private var searchText = ""

    private var filteredItems: [TransferCenter.Item] {
        guard !searchText.isEmpty else { return center.items }
        return center.items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var uploads: [TransferCenter.Item] {
        filteredItems.filter { $0.direction == .upload }
    }

    private var downloads: [TransferCenter.Item] {
        filteredItems.filter { $0.direction == .download }
    }

    private var imports: [TransferCenter.Item] {
        filteredItems.filter { $0.direction == .inbound }
    }

    private var hasFinishedTransfers: Bool {
        center.items.contains(where: { $0.state == .complete || $0.state == .failed })
    }

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.08).ignoresSafeArea()

            if filteredItems.isEmpty {
                if !searchText.isEmpty {
                    NoSearchResultsView(query: searchText)
                } else {
                    emptyState
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !uploads.isEmpty {
                            transferSection(title: "Uploads", items: uploads)
                        }

                        if !downloads.isEmpty {
                            transferSection(title: "Downloads", items: downloads)
                        }

                        if !imports.isEmpty {
                            transferSection(title: "Imports", items: imports)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 32)
                }
            }
        }
        .navigationTitle("Transfers")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .toolbar {
            if hasFinishedTransfers {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") {
                        center.clearFinished()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(XTheme.accent)
                }
            }
        }
    }

    private func transferSection(title: String, items: [TransferCenter.Item]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(title.uppercased()) (\(items.count))")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.40))
                .tracking(0.6)
                .padding(.horizontal, 4)

            VStack(spacing: 8) {
                ForEach(items) { item in
                    IOSTransferCard(item: item)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 48))
                .foregroundStyle(XTheme.accent)
            Text("No Active Transfers")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("Uploads, downloads, and link imports will appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - iOS Transfer Card

struct IOSTransferCard: View {
    let item: TransferCenter.Item
    @Environment(AppState.self) private var appState
    @State private var thumbURL: URL? = nil

    private var center: TransferCenter { TransferCenter.shared }

    private var statusColor: Color {
        switch item.state {
        case .failed: return .red
        case .paused: return .orange
        case .complete: return .green
        case .active: return XTheme.accent
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            leadingIcon

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    if item.state == .active || item.state == .paused {
                        Text("\(Int(item.progress * 100))%")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(statusColor)
                    }
                }

                // Progress Bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 4)

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [statusColor, statusColor.opacity(0.65)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, geo.size.width * CGFloat(min(max(item.progress, 0), 1))), height: 4)
                            .animation(.easeInOut(duration: 0.2), value: item.progress)
                    }
                }
                .frame(height: 4)

                HStack {
                    Text(item.statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)

                    Spacer()

                    if item.state == .complete {
                        Text("Show in Folder")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(XTheme.accent)
                    }
                }
            }

            trailingAction
        }
        .padding(14)
        .frostedGlassCard(cornerRadius: 16)
        .contentShape(Rectangle())
        .onTapGesture {
            if item.state == .complete {
                revealInFolder()
            }
        }
        .contextMenu {
            transferContextMenu
        }
        .task(id: item.id) {
            await loadThumbnail()
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if let thumbURL {
            AsyncImage(url: thumbURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                default:
                    iconFallback
                }
            }
        } else {
            iconFallback
        }
    }

    private var iconFallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(statusColor.opacity(0.15))
                .frame(width: 40, height: 40)

            Image(systemName: directionIconName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(statusColor)
        }
    }

    private var directionIconName: String {
        switch item.state {
        case .complete: return "checkmark"
        case .failed: return "exclamationmark.triangle.fill"
        default:
            switch item.direction {
            case .upload: return "arrow.up"
            case .download: return "arrow.down"
            case .inbound: return "tray.and.arrow.down"
            }
        }
    }

    @ViewBuilder
    private var trailingAction: some View {
        switch item.state {
        case .active:
            Button {
                center.cancel(item.id)
            } label: {
                Image(systemName: "pause.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.orange)
                    .frame(width: 28, height: 28)
                    .background(Color.orange.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
        case .paused:
            Button {
                Task { await center.resume(item.id) }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.orange)
                    .frame(width: 28, height: 28)
                    .background(Color.orange.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
        case .failed:
            Button {
                Task { await center.resume(item.id) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.red)
                    .frame(width: 28, height: 28)
                    .background(Color.red.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.green)
                .frame(width: 28, height: 28)
        }
    }

    @ViewBuilder
    private var transferContextMenu: some View {
        switch item.state {
        case .active:
            Button {
                center.cancel(item.id)
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            Button(role: .destructive) {
                center.discard(item.id)
            } label: {
                Label("Cancel Transfer", systemImage: "xmark.circle")
            }
        case .paused:
            Button {
                Task { await center.resume(item.id) }
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            Button(role: .destructive) {
                center.discard(item.id)
            } label: {
                Label("Delete Transfer", systemImage: "trash")
            }
        case .failed:
            Button {
                Task { await center.resume(item.id) }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                center.discard(item.id)
            } label: {
                Label("Delete Transfer", systemImage: "trash")
            }
        case .complete:
            Button {
                revealInFolder()
            } label: {
                Label("Show in Folder", systemImage: "folder")
            }
            Button {
                center.removeItems(forObjectID: item.objectID)
            } label: {
                Label("Remove from List", systemImage: "xmark.circle")
            }
        }
    }

    private func revealInFolder() {
        Task {
            if let obj = try? await DatabaseManager.shared.object(item.objectID) {
                appState.revealObject(obj)
            }
        }
    }

    private func loadThumbnail() async {
        guard item.state == .complete, item.direction != .upload else { return }
        if let thumbDir = try? UploadEngine.thumbnailsDirectory() {
            let jpg = thumbDir.appendingPathComponent("\(item.objectID)-tg.jpg")
            if FileManager.default.fileExists(atPath: jpg.path) {
                thumbURL = jpg
                return
            }
            let png = thumbDir.appendingPathComponent("\(item.objectID)-tg.png")
            if FileManager.default.fileExists(atPath: png.path) {
                thumbURL = png
                return
            }
        }
    }
}

// MARK: - Archive View

struct ArchiveView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var viewMode: ViewMode = .grid
    @State private var viewportHeight: CGFloat = 0
    @State private var isSelecting = false
    @State private var selectedFileIDs: Set<String> = []

    enum ViewMode: String {
        case grid = "Icons"
        case list = "List"
    }

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.08).ignoresSafeArea()

            Group {
                if filteredArchived.isEmpty {
                    if !searchText.isEmpty {
                        NoSearchResultsView(query: searchText)
                    } else {
                        emptyState
                    }
                } else if viewMode == .grid {
                    gridView
                } else {
                    listView
                }
            }
        }
        .navigationTitle("Archive")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectedFileIDs.count == filteredArchived.count ? "Deselect All" : "Select All") {
                        if selectedFileIDs.count == filteredArchived.count {
                            selectedFileIDs.removeAll()
                        } else {
                            selectedFileIDs = Set(filteredArchived.map(\.id))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isSelecting = false
                        selectedFileIDs.removeAll()
                    }
                    .fontWeight(.semibold)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        StandardAddMenu(folderID: "", isPrivate: false)

                        BlueEllipsisMenu {
                            Button {
                                isSelecting = true
                            } label: {
                                Label("Select", systemImage: "checkmark.circle")
                            }
                            Divider()
                            Button { viewMode = .grid } label: {
                                HStack {
                                    Text("Icons")
                                    if viewMode == .grid { Image(systemName: "checkmark") }
                                }
                            }
                            Button { viewMode = .list } label: {
                                HStack {
                                    Text("List")
                                    if viewMode == .list { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBottomBar
            }
        }
    }

    private var selectionBottomBar: some View {
        HStack {
            Button {
                appState.toggleArchive(selectedFileIDs)
                selectedFileIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "tray.and.arrow.up")
                        .font(.system(size: 20))
                    Text("Unarchive")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button(role: .destructive) {
                appState.trashFiles(selectedFileIDs)
                selectedFileIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.system(size: 20))
                    Text("Delete")
                        .font(.system(size: 10))
                }
                .foregroundStyle(selectedFileIDs.isEmpty ? Color.secondary : Color.red)
            }
            .disabled(selectedFileIDs.isEmpty)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 10)
        .background(Material.bar)
    }

    private var archivedFiles: [FileItem] {
        appState.allFiles.filter { $0.isArchived && !$0.trashed }
    }

    private var filteredArchived: [FileItem] {
        guard !searchText.isEmpty else { return archivedFiles }
        return archivedFiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "archivebox")
                .font(.system(size: 48))
                .foregroundStyle(XTheme.accent)
            Text("No Archived Files")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("Archived files are stored safely in cold storage.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var gridView: some View {
        ScrollView {
            VStack(spacing: 0) {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ], spacing: 28) {
                    ForEach(filteredArchived) { file in
                        if isSelecting {
                            FileGridItem(
                                file: file,
                                isSelecting: true,
                                isSelected: selectedFileIDs.contains(file.id)
                            ) {
                                toggleSelection(file.id)
                            }
                        } else {
                            FileGridItem(file: file) {
                                appState.openFile(file)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer(minLength: 40)

                PageItemCountFooter(count: filteredArchived.count)
                    .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: max(0, viewportHeight - 16), alignment: .top)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewportHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, newHeight in viewportHeight = newHeight }
            }
        }
    }

    private var listView: some View {
        List {
            ForEach(filteredArchived) { file in
                if isSelecting {
                    FileRow(
                        file: file,
                        isSelecting: true,
                        isSelected: selectedFileIDs.contains(file.id)
                    ) {
                        toggleSelection(file.id)
                    }
                } else {
                    FileRow(file: file) {
                        appState.openFile(file)
                    }
                }
            }

            PageItemCountFooter(count: filteredArchived.count)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
    }

    private func toggleSelection(_ id: String) {
        if selectedFileIDs.contains(id) {
            selectedFileIDs.remove(id)
        } else {
            selectedFileIDs.insert(id)
        }
    }
}

// MARK: - Trash View (Recently Deleted, Files-app style)

struct TrashView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var viewMode: ViewMode = .grid
    @State private var viewportHeight: CGFloat = 0
    @State private var isSelecting = false
    @State private var selectedFileIDs: Set<String> = []
    @State private var showEmptyTrashConfirmation = false

    enum ViewMode: String {
        case grid = "Icons"
        case list = "List"
    }

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.08)
                .ignoresSafeArea()

            if filteredTrash.isEmpty {
                if !searchText.isEmpty {
                    NoSearchResultsView(query: searchText)
                } else {
                    emptyState
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        Text("Recently deleted items may be permanently deleted by your storage provider.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)

                        if viewMode == .grid {
                            LazyVGrid(columns: [
                                GridItem(.flexible(), spacing: 16),
                                GridItem(.flexible(), spacing: 16),
                                GridItem(.flexible(), spacing: 16)
                            ], spacing: 28) {
                                ForEach(filteredTrash) { file in
                                    if isSelecting {
                                        FileGridItem(
                                            file: file,
                                            isSelecting: true,
                                            isSelected: selectedFileIDs.contains(file.id)
                                        ) {
                                            toggleSelection(file.id)
                                        }
                                    } else {
                                        FileGridItem(file: file) { }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(filteredTrash) { file in
                                    if isSelecting {
                                        FileRow(
                                            file: file,
                                            isSelecting: true,
                                            isSelected: selectedFileIDs.contains(file.id)
                                        ) {
                                            toggleSelection(file.id)
                                        }
                                    } else {
                                        FileRow(file: file) { }
                                    }
                                    Divider().padding(.leading, 60)
                                }
                            }
                        }

                        Spacer(minLength: 40)

                        PageItemCountFooter(count: filteredTrash.count, showSyncStatus: false)
                            .padding(.bottom, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: max(0, viewportHeight - 16), alignment: .top)
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { viewportHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { _, newHeight in viewportHeight = newHeight }
                    }
                }
            }
        }
        .navigationTitle("Recently Deleted")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectedFileIDs.count == filteredTrash.count ? "Deselect All" : "Select All") {
                        if selectedFileIDs.count == filteredTrash.count {
                            selectedFileIDs.removeAll()
                        } else {
                            selectedFileIDs = Set(filteredTrash.map(\.id))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isSelecting = false
                        selectedFileIDs.removeAll()
                    }
                    .fontWeight(.semibold)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    BlueEllipsisMenu {
                        Button {
                            isSelecting = true
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                        Divider()
                        Button { viewMode = .grid } label: {
                            HStack {
                                Text("Icons")
                                if viewMode == .grid { Image(systemName: "checkmark") }
                            }
                        }
                        Button { viewMode = .list } label: {
                            HStack {
                                Text("List")
                                if viewMode == .list { Image(systemName: "checkmark") }
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            showEmptyTrashConfirmation = true
                        } label: {
                            Label("Empty Bin", systemImage: "trash")
                        }
                        .disabled(trashedFiles.isEmpty)
                    }
                }
            }
        }
        .confirmationDialog(
            "Are you sure you want to permanently erase all items in the Bin?",
            isPresented: $showEmptyTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button("Empty Bin", role: .destructive) {
                appState.emptyTrash()
            }
            Button("Cancel", role: .cancel) {}
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBottomBar
            }
        }
    }

    private var selectionBottomBar: some View {
        HStack {
            Button {
                appState.restoreFiles(selectedFileIDs)
                selectedFileIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 20))
                    Text("Recover")
                        .font(.system(size: 10))
                }
            }
            .disabled(selectedFileIDs.isEmpty)

            Spacer()

            Button(role: .destructive) {
                appState.deletePermanently(selectedFileIDs)
                selectedFileIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 20))
                    Text("Delete Immediately")
                        .font(.system(size: 10))
                }
                .foregroundStyle(selectedFileIDs.isEmpty ? Color.secondary : Color.red)
            }
            .disabled(selectedFileIDs.isEmpty)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 10)
        .background(Material.bar)
    }

    private var trashedFiles: [FileItem] {
        appState.allFiles.filter { $0.trashed }
    }

    private var filteredTrash: [FileItem] {
        guard !searchText.isEmpty else { return trashedFiles }
        return trashedFiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "trash")
                .font(.system(size: 48))
                .foregroundStyle(XTheme.accent)
            Text("No Recently Deleted Files")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("Deleted files will appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    private func toggleSelection(_ id: String) {
        if selectedFileIDs.contains(id) {
            selectedFileIDs.remove(id)
        } else {
            selectedFileIDs.insert(id)
        }
    }
}

// MARK: - Apple Files Folder Icon

struct AppleFolderTabShape: Shape {
    var bodyYFraction: CGFloat = 0.13
    var tabWFraction: CGFloat = 0.40
    var cornerRadiusFraction: CGFloat = 0.11

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        let bodyY = height * bodyYFraction
        let tabW = width * tabWFraction
        let cornerRadius = height * cornerRadiusFraction
        let r = cornerRadius * 0.75

        path.move(to: CGPoint(x: 0, y: r))
        path.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: tabW - r, y: 0))
        path.addCurve(
            to: CGPoint(x: tabW + width * 0.09, y: bodyY),
            control1: CGPoint(x: tabW + r * 0.6, y: 0),
            control2: CGPoint(x: tabW + r * 0.3, y: bodyY)
        )
        path.addLine(to: CGPoint(x: width - cornerRadius, y: bodyY))
        path.addQuadCurve(to: CGPoint(x: width, y: bodyY + cornerRadius), control: CGPoint(x: width, y: bodyY))
        path.addLine(to: CGPoint(x: width, y: height - cornerRadius))
        path.addQuadCurve(to: CGPoint(x: width - cornerRadius, y: height), control: CGPoint(x: width, y: height))
        path.addLine(to: CGPoint(x: cornerRadius, y: height))
        path.addQuadCurve(to: CGPoint(x: 0, y: height - cornerRadius), control: CGPoint(x: 0, y: height))
        path.closeSubpath()
        return path
    }
}

struct AppleFolderIcon: View {
    var width: CGFloat = 84
    var height: CGFloat = 66

    var body: some View {
        let bodyY = height * 0.13
        let cornerRadius = height * 0.11

        ZStack(alignment: .topLeading) {
            // Back Tab / Flap
            AppleFolderTabShape()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 60/255, green: 160/255, blue: 222/255),
                            Color(red: 50/255, green: 146/255, blue: 206/255)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: width, height: height)

            // Front Main Body
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 104/255, green: 194/255, blue: 242/255),
                            Color(red: 80/255, green: 172/255, blue: 226/255)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    // Subtle top highlight border along front body
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.40), Color.white.opacity(0.06)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )
                )
                .frame(width: width, height: height - bodyY)
                .offset(y: bodyY)
        }
        .frame(width: width, height: height)
    }
}

// MARK: - Inline New Folder Items (Files-app style)

struct InlineNewFolderGridItem: View {
    @Environment(AppState.self) private var appState
    let parentID: String
    let filterPrivate: Bool
    @State private var folderName: String = "untitled folder"
    @FocusState private var isFocused: Bool
    @State private var isCommitted: Bool = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .bottom) {
                AppleFolderIcon(width: 84, height: 66)
                    .shadow(color: .black.opacity(0.15), radius: 2.5, x: 0, y: 1.5)
            }
            .frame(height: 94, alignment: .bottom)
            .frame(maxWidth: .infinity)

            VStack(spacing: 2) {
                TextField("Folder Name", text: $folderName)
                    .font(.system(size: 13, weight: .regular))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(uiColor: .systemGray5))
                    )
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit {
                        commit()
                    }
                    .onChange(of: isFocused) { _, focused in
                        if !focused {
                            commit()
                        }
                    }

                Text("0 items")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear {
            // Give menu dismissal animation time to complete before raising keyboard to prevent stutter
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                isFocused = true
            }
        }
    }

    private func commit() {
        guard !isCommitted else { return }
        isCommitted = true
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "untitled folder" : trimmed
        appState.createFolder(named: finalName, parentID: parentID, isPrivate: filterPrivate)
    }
}

struct InlineNewFolderRow: View {
    @Environment(AppState.self) private var appState
    let parentID: String
    let filterPrivate: Bool
    @State private var folderName: String = "untitled folder"
    @FocusState private var isFocused: Bool
    @State private var isCommitted: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            AppleFolderIcon(width: 36, height: 28)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                TextField("Folder Name", text: $folderName)
                    .font(.body)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(uiColor: .systemGray5))
                    )
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit {
                        commit()
                    }
                    .onChange(of: isFocused) { _, focused in
                        if !focused {
                            commit()
                        }
                    }

                Text("0 items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                isFocused = true
            }
        }
    }

    private func commit() {
        guard !isCommitted else { return }
        isCommitted = true
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "untitled folder" : trimmed
        appState.createFolder(named: finalName, parentID: parentID, isPrivate: filterPrivate)
    }
}

// MARK: - Reveal Flash Ring

struct RevealFlashRing: View {
    @Environment(AppState.self) private var appState
    let fileID: String
    @State private var pulse: CGFloat = 0
    @State private var scale: CGFloat = 0.96

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(XTheme.accent.opacity(0.12 * pulse))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(XTheme.accent, lineWidth: 2.5)
                .shadow(color: XTheme.accent.opacity(0.8), radius: 8)
                .opacity(pulse)
        }
        .scaleEffect(scale)
        .allowsHitTesting(false)
        .onAppear {
            startFlash()
        }
    }

    private func startFlash() {
        Task { @MainActor in
            for _ in 0..<2 {
                withAnimation(.easeOut(duration: 0.16)) {
                    pulse = 1
                    scale = 1.0
                }
                try? await Task.sleep(nanoseconds: 160_000_000)
                withAnimation(.easeIn(duration: 0.20)) {
                    pulse = 0
                    scale = 1.04
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if appState.revealObjectID == fileID {
                appState.revealObjectID = nil
            }
        }
    }
}

// MARK: - File Row

struct FileRow: View {
    @Environment(AppState.self) private var appState
    let file: FileItem
    var isSelecting: Bool = false
    var isSelected: Bool = false
    var onTap: (() -> Void)? = nil
    @State private var renameText = ""
    @State private var showInfo = false
    @State private var thumbData: Data?
    @FocusState private var isRenameFocused: Bool

    var isRenaming: Bool {
        appState.editingFileID == file.id
    }

    var body: some View {
        rowContent
            .contentShape(Rectangle())
            .overlay {
                if file.id == appState.revealObjectID {
                    RevealFlashRing(fileID: file.id)
                }
            }
            .task(id: "\(file.id)-\(appState.thumbnailVersion)") {
                guard !file.isFolder else { return }
                // Use already-loaded data from the bulk pass if available
                if let existing = file.thumbnailData {
                    thumbData = existing
                    return
                }
                // Lazy on-demand fetch
                if let data = await appState.fetchSingleThumbnail(for: file.id) {
                    await MainActor.run {
                        thumbData = data
                        if let idx = appState.allFiles.firstIndex(where: { $0.id == file.id }) {
                            appState.allFiles[idx].thumbnailData = data
                        }
                    }
                }
            }
            .contextMenu {
                ControlGroup {
                    Button {
                        appState.duplicateFile(file)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }

                    Button {
                        appState.presentMoveSheet(for: [file.id])
                    } label: {
                        Label("Move", systemImage: "folder")
                    }

                    Button {
                        appState.presentShareSheet(for: file)
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }

                if !file.isFolder {
                    Button {
                        appState.openFile(file)
                    } label: {
                        Label("Quick Look", systemImage: "eye")
                    }
                }

                Button {
                    showInfo = true
                } label: {
                    Label("Get Info", systemImage: "info.circle")
                }

                Button {
                    startRenaming()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button {
                    appState.toggleArchive([file.id])
                } label: {
                    Label(file.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox")
                }

                Button {
                    appState.duplicateFile(file)
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }

                Button {
                    appState.createFolderWithItem(file)
                } label: {
                    Label("New Folder with Item", systemImage: "folder.badge.plus")
                }

                Button {
                    appState.toggleFavorite(file)
                } label: {
                    Label(file.isFavorite ? "Unfavorite" : "Favorite", systemImage: file.isFavorite ? "star.fill" : "star")
                }

                Divider()

                Button(role: .destructive) {
                    appState.trashFile(file)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .alert("File Info", isPresented: $showInfo) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(appState.getInfo(file))
            }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            if isSelecting {
                ZStack {
                    if isSelected {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 22, height: 22)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Circle()
                            .strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5)
                            .frame(width: 22, height: 22)
                    }
                }
            }

            // Thumbnail / Icon tap target (opens file/folder)
            Button {
                if isSelecting {
                    onTap?()
                } else if isRenaming {
                    commitRename()
                } else {
                    onTap?()
                }
            } label: {
                thumbnailView
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Name", text: $renameText)
                        .font(.body)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(uiColor: .systemGray5))
                        )
                        .focused($isRenameFocused)
                        .submitLabel(.done)
                        .onSubmit {
                            commitRename()
                        }
                        .onChange(of: isRenameFocused) { _, focused in
                            if !focused {
                                commitRename()
                            }
                        }
                        .onAppear {
                            renameText = file.name
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                isRenameFocused = true
                            }
                        }
                } else {
                    // Tapping filename directly starts inline rename (or selects if in selection mode)
                    Button {
                        if isSelecting {
                            onTap?()
                        } else {
                            startRenaming()
                        }
                    } label: {
                        Text(file.name)
                            .font(.body)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }

                if file.isFolder {
                    Text("\(countChildren) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Text(file.formattedDate)
                        if let size = file.formattedSize {
                            Text(size)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
    }

    private func startRenaming() {
        renameText = file.name
        appState.editingFileID = file.id
    }

    private func commitRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != file.name {
            appState.renameFile(file, to: trimmed)
        }
        if appState.editingFileID == file.id {
            appState.editingFileID = nil
        }
    }

    private var countChildren: Int {
        appState.allFiles.filter { $0.parentID == file.id && !$0.trashed && !$0.isArchived }.count
    }

    @ViewBuilder
    private var thumbnailView: some View {
        let effectiveThumb = thumbData ?? file.thumbnailData
        if file.isFolder {
            AppleFolderIcon(width: 36, height: 28)
        } else if let data = effectiveThumb, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else if file.isAudio {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.12), radius: 1)
                Image(systemName: "music.note")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(white: 0.65))
            }
        } else if file.isDocument {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.12), radius: 1)
                Image(systemName: "doc.text")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(white: 0.65))
            }
        } else if file.isVideo {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(red: 0.14, green: 0.14, blue: 0.16))
                Image(systemName: "film")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.80))
            }
        } else if file.isImage {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(red: 0.16, green: 0.18, blue: 0.22))
                Image(systemName: "photo")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.80))
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                Image(systemName: file.systemIcon)
                    .font(.system(size: 16))
                    .foregroundStyle(XTheme.accent)
            }
        }
    }
}

// MARK: - File Grid Item

struct FileGridItem: View {
    @Environment(AppState.self) private var appState
    let file: FileItem
    var isSelecting: Bool = false
    var isSelected: Bool = false
    var onTap: (() -> Void)? = nil
    @State private var renameText = ""
    @State private var showInfo = false
    @State private var thumbData: Data?
    @FocusState private var isRenameFocused: Bool

    var isRenaming: Bool {
        appState.editingFileID == file.id
    }

    var body: some View {
        Group {
            if let onTap {
                Button {
                    if isRenaming {
                        commitRename()
                    } else {
                        onTap()
                    }
                } label: {
                    gridContent
                }
                .buttonStyle(.plain)
            } else {
                gridContent
            }
        }
        .contentShape(Rectangle())
        .overlay {
            if file.id == appState.revealObjectID {
                RevealFlashRing(fileID: file.id)
            }
        }
        .task(id: "\(file.id)-\(appState.thumbnailVersion)") {
            guard !file.isFolder else { return }
            // Use already-loaded data from the bulk pass if available
            if let existing = file.thumbnailData {
                thumbData = existing
                return
            }
            // Lazy on-demand fetch
            if let data = await appState.fetchSingleThumbnail(for: file.id) {
                await MainActor.run {
                    thumbData = data
                    if let idx = appState.allFiles.firstIndex(where: { $0.id == file.id }) {
                        appState.allFiles[idx].thumbnailData = data
                    }
                }
            }
        }
        .contextMenu {
            ControlGroup {
                Button {
                    appState.duplicateFile(file)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                Button {
                    appState.presentMoveSheet(for: [file.id])
                } label: {
                    Label("Move", systemImage: "folder")
                }

                Button {
                    appState.presentShareSheet(for: file)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }

            if !file.isFolder {
                Button {
                    appState.openFile(file)
                } label: {
                    Label("Quick Look", systemImage: "eye")
                }
            }

            Button {
                showInfo = true
            } label: {
                Label("Get Info", systemImage: "info.circle")
            }

            Button {
                startRenaming()
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                appState.toggleArchive([file.id])
            } label: {
                Label(file.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox")
            }

            Button {
                appState.duplicateFile(file)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }

            Button {
                appState.createFolderWithItem(file)
            } label: {
                Label("New Folder with Item", systemImage: "folder.badge.plus")
            }

            Button {
                appState.toggleFavorite(file)
            } label: {
                Label(file.isFavorite ? "Unfavorite" : "Favorite", systemImage: file.isFavorite ? "star.fill" : "star")
            }

            Divider()

            Button(role: .destructive) {
                appState.trashFile(file)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .alert("File Info", isPresented: $showInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.getInfo(file))
        }
    }

    private var gridContent: some View {
        VStack(spacing: 5) {
            // Card container / thumbnail
            ZStack(alignment: .bottom) {
                thumbnailView
                    .frame(height: 94, alignment: .bottom)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())

                if isSelecting {
                    ZStack {
                        if isSelected {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 24, height: 24)
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Circle()
                                .fill(Color.black.opacity(0.18))
                                .frame(width: 24, height: 24)
                            Circle()
                                .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
                                .frame(width: 24, height: 24)
                                .shadow(color: .black.opacity(0.20), radius: 1, x: 0, y: 1)
                        }
                    }
                    .padding(.bottom, 6)
                }
            }

            // Labels
            VStack(spacing: 2) {
                if isRenaming {
                    TextField("Name", text: $renameText)
                        .font(.system(size: 13, weight: .regular))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(uiColor: .systemGray5))
                        )
                        .focused($isRenameFocused)
                        .submitLabel(.done)
                        .onSubmit {
                            commitRename()
                        }
                        .onChange(of: isRenameFocused) { _, focused in
                            if !focused {
                                commitRename()
                            }
                        }
                        .onAppear {
                            renameText = file.name
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                isRenameFocused = true
                            }
                        }
                } else {
                    Text(file.name)
                        .font(.system(size: 13, weight: .regular))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                }

                if file.isFolder {
                    Text("\(countChildren) \(countChildren == 1 ? "item" : "items")")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                } else {
                    Text(file.formattedDate)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                    if let size = file.formattedSize {
                        Text(size)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func startRenaming() {
        renameText = file.name
        appState.editingFileID = file.id
    }

    private func commitRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != file.name {
            appState.renameFile(file, to: trimmed)
        }
        if appState.editingFileID == file.id {
            appState.editingFileID = nil
        }
    }

    private var countChildren: Int {
        appState.allFiles.filter { $0.parentID == file.id && !$0.trashed && !$0.isArchived }.count
    }

    @ViewBuilder
    private var thumbnailView: some View {
        let effectiveThumb = thumbData ?? file.thumbnailData
        if file.isFolder {
            AppleFolderIcon(width: 84, height: 66)
                .shadow(color: .black.opacity(0.15), radius: 2.5, x: 0, y: 1.5)
        } else if let data = effectiveThumb, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 94)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 2.5, x: 0, y: 1.5)
        } else if file.isAudio {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 70, height: 92)
                    .shadow(color: .black.opacity(0.16), radius: 2.5, x: 0, y: 1.5)
                Image(systemName: "music.note")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Color(white: 0.78))
            }
        } else if file.isDocument {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 70, height: 92)
                    .shadow(color: .black.opacity(0.18), radius: 2.5, x: 0, y: 1.5)
                VStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 28))
                        .foregroundStyle(Color(white: 0.65))
                    let ext = (file.name as NSString).pathExtension.uppercased()
                    if !ext.isEmpty {
                        Text(ext)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(white: 0.45))
                    }
                }
            }
        } else if file.isVideo {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(red: 0.13, green: 0.13, blue: 0.15))
                    .frame(width: 90, height: 60)
                    .shadow(color: .black.opacity(0.20), radius: 2.5, x: 0, y: 1.5)
                VStack(spacing: 3) {
                    Image(systemName: "film")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.75))
                    let ext = (file.name as NSString).pathExtension.uppercased()
                    if !ext.isEmpty {
                        Text(ext)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.50))
                    }
                }
            }
        } else if file.isImage {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(red: 0.16, green: 0.18, blue: 0.22))
                    .frame(width: 84, height: 62)
                    .shadow(color: .black.opacity(0.18), radius: 2.5, x: 0, y: 1.5)
                VStack(spacing: 3) {
                    Image(systemName: "photo")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.70))
                    let ext = (file.name as NSString).pathExtension.uppercased()
                    if !ext.isEmpty {
                        Text(ext)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.50))
                    }
                }
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .frame(width: 70, height: 92)
                    .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                VStack(spacing: 4) {
                    Image(systemName: file.systemIcon)
                        .font(.system(size: 28))
                        .foregroundStyle(XTheme.accent)
                    let ext = (file.name as NSString).pathExtension.uppercased()
                    if !ext.isEmpty {
                        Text(ext)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Login Gate

struct LoginGateView: View {
    @Environment(AppState.self) private var appState
    @State private var showSetup = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                VStack(spacing: 32) {
                    Spacer()
                    VStack(spacing: 12) {
                        Image("CascadeLogo")
                            .resizable()
                            .renderingMode(.original)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 80, height: 80)
                        Text("Cascade")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        Text("Your private cloud")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !appState.hasTelegramCredentials {
                        VStack(spacing: 16) {
                            Text("Connect your Telegram account to access your encrypted vault.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                            Button { showSetup = true } label: {
                                Text("Get Started")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(.blue)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .padding(.horizontal, 32)
                        }
                    } else {
                        LoginStepsView()
                    }
                    Spacer()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if appState.databaseError != nil || appState.hasTelegramCredentials {
                        Button("Back") { appState.logout() }
                            .foregroundStyle(XTheme.accent)
                    }
                }
            }
        }
        .task {
            if appState.hasTelegramCredentials, !TelegramClient.shared.isClientStarted {
                if let creds = try? KeychainStore.loadTelegramCredentials() {
                    await appState.startTelegram(apiID: creds.apiID, apiHash: creds.apiHash)
                }
            }
        }
        .sheet(isPresented: $showSetup) {
            TelegramSetupSheet()
        }
    }
}

// MARK: - Setup Sheet

struct TelegramSetupSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var apiID: String = ""
    @State private var apiHash: String = ""
    @State private var errorMessage: String?
    @State private var isConnecting = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case apiID, apiHash }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 4) {
                        Image(systemName: "key.fill")
                            .font(.title2)
                            .foregroundStyle(XTheme.accent)
                        Text("Telegram API")
                            .font(.headline)
                        Text("Get these from my.telegram.org")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                Section("Credentials") {
                    TextField("API ID", text: $apiID)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .apiID)
                        .onSubmit { focusedField = .apiHash }
                    SecureField("API Hash", text: $apiHash)
                        .focused($focusedField, equals: .apiHash)
                        .onSubmit { connect() }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Connect") { connect() }
                        .disabled(apiID.isEmpty || apiHash.isEmpty || isConnecting)
                }
            }
        }
        .onAppear { focusedField = .apiID }
    }

    private func connect() {
        guard let id = Int(apiID), !apiHash.isEmpty else {
            errorMessage = "Enter valid API ID and Hash"
            return
        }
        errorMessage = nil
        isConnecting = true
        Task {
            await appState.startTelegram(apiID: id, apiHash: apiHash)
            isConnecting = false
            if appState.hasTelegramCredentials { dismiss() }
            else { errorMessage = appState.databaseError ?? "Connection failed" }
        }
    }
}

// MARK: - Login Steps

struct LoginStepsView: View {
    @Environment(AppState.self) private var appState
    @State private var phoneNumber = ""
    @State private var dialCode = "+1"
    @State private var authCode = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case phone, code, password }

    var body: some View {
        VStack(spacing: 20) {
            switch TelegramClient.shared.authStep {
            case .phone: phoneView
            case .code: codeView
            case .password: passwordView
            case .confirmation: confirmationView
            default: ProgressView().padding(.vertical, 20)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 32)
        .animation(.easeInOut(duration: 0.2), value: TelegramClient.shared.authStep)
    }

    private var phoneView: some View {
        VStack(spacing: 14) {
            Text("Enter your phone number").font(.headline)
            HStack(spacing: 8) {
                TextField("+1", text: $dialCode)
                    .textFieldStyle(.plain)
                    .frame(width: 56)
                    .padding(10)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .keyboardType(.phonePad)
                    .focused($focusedField, equals: .phone)
                TextField("234 567 8900", text: $phoneNumber)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .keyboardType(.phonePad)
                    .focused($focusedField, equals: .phone)
            }
            Button { Task { await sendPhone() } } label: {
                if isLoading { ProgressView().tint(.white) } else { Text("Send Code") }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(phoneNumber.isEmpty ? Color.gray.opacity(0.3) : .blue)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .disabled(phoneNumber.isEmpty || isLoading)
        }
        .onAppear { focusedField = .phone }
    }

    private var codeView: some View {
        VStack(spacing: 14) {
            Text("Verification Code").font(.headline)
            Text("Enter the code sent to your phone")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("00000", text: $authCode)
                .textFieldStyle(.plain)
                .font(.title2.monospacedDigit().bold())
                .multilineTextAlignment(.center)
                .padding(12)
                .background(Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .keyboardType(.numberPad)
                .focused($focusedField, equals: .code)
                .onChange(of: authCode) { _, newValue in
                    authCode = String(newValue.prefix(5).filter(\.isNumber))
                }
            Button { focusedField = nil; Task { await verifyCode() } } label: {
                if isLoading { ProgressView().tint(.white) } else { Text("Verify") }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(authCode.count < 5 ? Color.gray.opacity(0.3) : .blue)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .disabled(authCode.count < 5 || isLoading)
        }
        .onAppear { authCode = ""; focusedField = .code }
    }

    private var passwordView: some View {
        VStack(spacing: 14) {
            Text("Two-Step Verification").font(.headline)
            SecureField("Password", text: $password)
                .textFieldStyle(.plain)
                .padding(12)
                .background(Color(.tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .focused($focusedField, equals: .password)
            Button { Task { await verifyPassword() } } label: {
                if isLoading { ProgressView().tint(.white) } else { Text("Verify") }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(password.isEmpty ? Color.gray.opacity(0.3) : .blue)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .disabled(password.isEmpty || isLoading)
        }
        .onAppear { focusedField = .password }
    }

    private var confirmationView: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 44))
                .foregroundStyle(XTheme.accent)
            Text("Confirm Login").font(.headline)
            Text("Approve this login from another device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 20)
    }

    private func sendPhone() async {
        isLoading = true; errorMessage = nil
        let full = "\(dialCode)\(phoneNumber)".replacingOccurrences(of: " ", with: "")
        do { try await TelegramClient.shared.setAuthenticationPhoneNumber(full) }
        catch { errorMessage = error.localizedDescription }
        isLoading = false
    }

    private func verifyCode() async {
        isLoading = true; errorMessage = nil
        do { try await TelegramClient.shared.checkAuthenticationCode(authCode) }
        catch { errorMessage = error.localizedDescription }
        isLoading = false
    }

    private func verifyPassword() async {
        isLoading = true; errorMessage = nil
        do { try await TelegramClient.shared.checkAuthenticationPassword(password) }
        catch { errorMessage = error.localizedDescription }
        isLoading = false
    }
}

// MARK: - Audio Player Views & Components

private func formatPlayerTime(_ seconds: Double) -> String {
    guard !seconds.isNaN && !seconds.isInfinite && seconds >= 0 else { return "00:00" }
    let total = Int(seconds)
    let s = total % 60
    let m = (total / 60) % 60
    let h = total / 3600
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%02d:%02d", m, s)
}

struct EqualizerWaveformView: View {
    let barCount: Int
    var isPlaying: Bool = true

    var body: some View {
        TimelineView(.animation) { timeline in
            let date = timeline.date.timeIntervalSince1970
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    let factor: Double = {
                        guard isPlaying else { return 0.15 }
                        let phase = Double(index) * 0.9
                        let speed = 4.0 + Double(index % 3) * 1.5
                        let primary = sin(date * speed + phase) * 0.45 + 0.55
                        let secondary = sin(date * 7.5 + phase * 2.0) * 0.25
                        return max(0.2, min(1.0, primary + secondary))
                    }()

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 3, height: CGFloat(factor * 16))
                }
            }
        }
    }
}

struct AudioMiniPlayerView: View {
    let track: FileItem
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 12) {
            // Artwork / Equalizer Icon
            ZStack {
                if let thumb = track.thumbnailData, let uiImage = UIImage(data: thumb) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 42, height: 42)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                        }
                }

                if appState.isAudioPlaying {
                    EqualizerWaveformView(barCount: 3, isPlaying: true)
                        .frame(width: 16, height: 16)
                        .background(Color.black.opacity(0.4), in: Circle())
                }
            }

            // Track info and time
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(formatPlayerTime(appState.audioCurrentTime) + " / " + formatPlayerTime(appState.audioDuration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            // Play / Pause Button
            Button {
                appState.toggleAudioPlayPause()
            } label: {
                Image(systemName: appState.isAudioPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
            }

            // Close Button
            Button {
                appState.stopAudio()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            appState.showFullAudioPlayer = true
        }
    }
}

struct FullAudioPlayerView: View {
    let track: FileItem
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0

    var body: some View {
        ZStack {
            // Ambient dynamic background glow
            LinearGradient(
                colors: [Color.blue.opacity(0.35), Color.purple.opacity(0.25), Color(.systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top Bar
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.primary)
                            .padding(10)
                            .background(Circle().fill(Color.primary.opacity(0.08)))
                    }

                    Spacer()

                    Text("NOW PLAYING")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .tracking(1.5)

                    Spacer()

                    Button {
                        appState.stopAudio()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.primary)
                            .padding(10)
                            .background(Circle().fill(Color.primary.opacity(0.08)))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                Spacer(minLength: 20)

                // Hero Artwork
                ZStack {
                    if let thumb = track.thumbnailData, let uiImage = UIImage(data: thumb) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 240, height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .shadow(color: Color.blue.opacity(0.4), radius: 24, y: 12)
                    } else {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 240, height: 240)
                            .overlay {
                                if appState.isAudioPlaying {
                                    EqualizerWaveformView(barCount: 5, isPlaying: true)
                                        .frame(width: 60, height: 50)
                                } else {
                                    Image(systemName: "music.note")
                                        .font(.system(size: 72, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .shadow(color: Color.purple.opacity(0.35), radius: 24, y: 12)
                    }
                }
                .scaleEffect(appState.isAudioPlaying ? 1.0 : 0.94)
                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: appState.isAudioPlaying)

                Spacer(minLength: 24)

                // Track Title & Details
                VStack(spacing: 6) {
                    Text(track.name)
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    HStack(spacing: 8) {
                        Text((track.name as NSString).pathExtension.uppercased())
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))

                        if let size = track.formattedSize {
                            Text(size)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 20)

                // Scrubber Slider & Timers
                VStack(spacing: 6) {
                    Slider(
                        value: Binding(
                            get: { isScrubbing ? scrubTime : appState.audioCurrentTime },
                            set: { newValue in
                                isScrubbing = true
                                scrubTime = newValue
                            }
                        ),
                        in: 0...max(1, appState.audioDuration),
                        onEditingChanged: { editing in
                            if !editing {
                                appState.seekAudio(to: scrubTime)
                                isScrubbing = false
                            }
                        }
                    )
                    .tint(.blue)

                    HStack {
                        Text(formatPlayerTime(isScrubbing ? scrubTime : appState.audioCurrentTime))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text(formatPlayerTime(appState.audioDuration))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 32)

                Spacer(minLength: 16)

                // Playback Transport Controls
                HStack(spacing: 36) {
                    // Skip -15s
                    Button {
                        appState.seekAudio(to: max(0, appState.audioCurrentTime - 15))
                    } label: {
                        Image(systemName: "gobackward.15")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(.primary)
                    }

                    // Play / Pause Circle
                    Button {
                        appState.toggleAudioPlayPause()
                    } label: {
                        Image(systemName: appState.isAudioPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 68, height: 68)
                            .background(Circle().fill(Color.blue))
                            .shadow(color: Color.blue.opacity(0.4), radius: 12, y: 6)
                    }

                    // Skip +15s
                    Button {
                        appState.seekAudio(to: min(appState.audioDuration, appState.audioCurrentTime + 15))
                    } label: {
                        Image(systemName: "goforward.15")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                }
                .padding(.bottom, 40)
            }
        }
    }
}

// MARK: - Import Share Link Modal Sheet

struct ImportShareLinkSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var linkText: String = ""
    @State private var passwordText: String = ""

    private var parsedLink: ShareEngine.ShareLink? {
        let trimmed = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ShareEngine.ShareLink.parse(trimmed)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Paste a Cascade share link (cascade://share#...) to import shared files directly into your drive.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            TextField("cascade://share#...", text: $linkText)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)

                            if UIPasteboard.general.hasStrings {
                                Button {
                                    if let string = UIPasteboard.general.string {
                                        linkText = string.trimmingCharacters(in: .whitespacesAndNewlines)
                                    }
                                } label: {
                                    Label("Paste", systemImage: "doc.on.clipboard")
                                        .labelStyle(.iconOnly)
                                        .font(.system(size: 16))
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                if let link = parsedLink {
                    Section("Share Details") {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.blue.opacity(0.12))
                                    .frame(width: 48, height: 48)

                                if link.isGroup || link.files.contains(where: { $0.path != nil }) {
                                    AppleFolderIcon(width: 40, height: 32)
                                } else {
                                    let ext = (link.fileName as NSString).pathExtension.lowercased()
                                    let isImage = ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(ext)
                                    let isVideo = ["mp4", "mov", "m4v", "mkv", "avi"].contains(ext)
                                    let isAudio = ["mp3", "m4a", "flac", "wav", "aac"].contains(ext)
                                    Image(systemName: isImage ? "photo.fill" : (isVideo ? "play.rectangle.fill" : (isAudio ? "music.note" : "doc.fill")))
                                        .font(.system(size: 22))
                                        .foregroundStyle(XTheme.accent)
                                }
                            }
                            .frame(width: 48, height: 48)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(link.fileName)
                                    .font(.headline)
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)

                                HStack(spacing: 6) {
                                    if link.isPasswordProtected {
                                        HStack(spacing: 3) {
                                            Image(systemName: "lock.fill")
                                                .font(.system(size: 10))
                                            Text("Protected")
                                                .font(.caption2.weight(.semibold))
                                        }
                                        .foregroundStyle(.orange)
                                    }

                                    let itemCount = link.files.count
                                    if itemCount > 1 {
                                        Text("\(itemCount) files")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else if link.files.contains(where: { $0.path != nil }) {
                                        Text("Folder")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("File")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if (parsedLink?.isPasswordProtected == true) || appState.pendingPasswordLink != nil || !passwordText.isEmpty {
                    Section("Password Protected") {
                        SecureField("Enter Password", text: $passwordText)
                    }
                }

                Section {
                    Button {
                        importLink()
                    } label: {
                        HStack {
                            Spacer()
                            if appState.isImportingShareLink {
                                ProgressView()
                                    .padding(.trailing, 6)
                            }
                            Text(appState.isImportingShareLink ? "Importing..." : "Import to Drive")
                                .font(.headline)
                                .foregroundStyle(linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.isImportingShareLink ? Color.secondary : Color.blue)
                            Spacer()
                        }
                    }
                    .disabled(linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.isImportingShareLink || ((parsedLink?.isPasswordProtected == true) && passwordText.isEmpty))
                }
            }
            .navigationTitle("Add from Share Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        appState.pendingPasswordLink = nil
                        dismiss()
                    }
                    .disabled(appState.isImportingShareLink)
                }
            }
            .onAppear {
                if let pending = appState.pendingPasswordLink {
                    linkText = pending
                } else if linkText.isEmpty, let clip = UIPasteboard.general.string, clip.hasPrefix("cascade://") {
                    linkText = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
    }

    private func importLink() {
        let trimmed = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            await appState.importShareLink(
                trimmed,
                password: passwordText.isEmpty ? nil : passwordText
            )
        }
    }
}
#endif
