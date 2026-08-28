#if os(iOS)
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct FileBrowserView: View {
    @Environment(AppState.self) private var appState
    var folderID: String = ""
    var folderTitle: String = "Cascade Drive"
    var filterPrivate: Bool = false

    @State private var searchText = ""
    @State private var viewMode: ViewMode = .grid
    @State private var sortBy: SortOption = .name
    @State private var sortAscending = true
    @State private var viewportHeight: CGFloat = 0

    @State private var isSelecting = false
    @State private var selectedFileIDs: Set<String> = []

    @State private var showFileImporter = false
    @State private var showPhotosPicker = false
    @State private var showCameraPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []

    enum ViewMode: String, CaseIterable {
        case grid = "Icons"
        case list = "List"
    }

    enum SortOption: String, CaseIterable {
        case name = "Name"
        case kind = "Kind"
        case date = "Date"
        case size = "Size"
    }

    var body: some View {
        Group {
            if filteredFiles.isEmpty && !appState.isCreatingFolder {
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
        .navigationTitle(isSelecting ? (selectedFileIDs.isEmpty ? "Select Items" : "\(selectedFileIDs.count) \(selectedFileIDs.count == 1 ? "Item" : "Items") Selected") : folderTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isSelecting)
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
                    HStack(spacing: 16) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewMode = (viewMode == .grid ? .list : .grid)
                            }
                        } label: {
                            Image(systemName: viewMode == .grid ? "list.bullet" : "square.grid.2x2")
                                .font(.system(size: 16, weight: .regular))
                        }

                        Button("Done") {
                            withAnimation {
                                isSelecting = false
                                selectedFileIDs.removeAll()
                            }
                        }
                        .fontWeight(.semibold)
                    }
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section {
                            Menu {
                                Button {
                                    showFileImporter = true
                                } label: {
                                    Label("Choose Files", systemImage: "folder")
                                }

                                Button {
                                    showPhotosPicker = true
                                } label: {
                                    Label("Photo Library", systemImage: "photo.on.rectangle")
                                }

                                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                    Button {
                                        showCameraPicker = true
                                    } label: {
                                        Label("Take Photo or Video", systemImage: "camera")
                                    }
                                }
                            } label: {
                                Label("Upload Files", systemImage: "arrow.up.doc")
                            }

                            Button {
                                appState.showImportShareSheet = true
                            } label: {
                                Label("Add from Share Link", systemImage: "link.badge.plus")
                            }

                            Button {
                                appState.startCreatingFolder(in: folderID)
                            } label: {
                                Label("New Folder", systemImage: "folder.badge.plus")
                            }

                            Button { } label: {
                                Label("Scan Documents", systemImage: "document.viewfinder")
                            }
                        }

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
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task {
                    await appState.uploadBatch(urls: urls, parentID: folderID.isEmpty ? nil : folderID, isPrivate: filterPrivate)
                }
            case .failure(let err):
                print("[iOS] File importer error: \(err)")
            }
        }
        .photosPicker(
            isPresented: $showPhotosPicker,
            selection: $selectedPhotoItems,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                await handlePhotosPicked(items)
                selectedPhotoItems.removeAll()
            }
        }
        .fullScreenCover(isPresented: $showCameraPicker) {
            CameraMediaPicker { capturedURL in
                Task {
                    await appState.uploadBatch(urls: [capturedURL], parentID: folderID.isEmpty ? nil : folderID, isPrivate: filterPrivate)
                }
            }
            .ignoresSafeArea()
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBottomBar
            }
        }
        .refreshable {
            await appState.loadAllFiles()
        }
    }

    private func handlePhotosPicked(_ items: [PhotosPickerItem]) async {
        var tempURLs: [URL] = []
        let tempDir = (try? UploadEngine.tempDirectory()) ?? FileManager.default.temporaryDirectory

        for (idx, item) in items.enumerated() {
            if let data = try? await item.loadTransferable(type: Data.self) {
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let filename = "Photo_\(Int(Date().timeIntervalSince1970))_\(idx + 1).\(ext)"
                let dest = tempDir.appendingPathComponent(filename)
                try? data.write(to: dest)
                tempURLs.append(dest)
            }
        }

        if !tempURLs.isEmpty {
            await appState.uploadBatch(urls: tempURLs, parentID: folderID.isEmpty ? nil : folderID, isPrivate: filterPrivate)
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

    private var currentFolderFiles: [FileItem] {
        if filterPrivate {
            return appState.allFiles.filter { $0.isPrivate && !$0.trashed && ($0.parentID ?? "") == folderID }
        } else {
            return appState.allFiles.filter { !$0.isPrivate && !$0.trashed && !$0.isArchived && ($0.parentID ?? "") == folderID }
        }
    }

    private var sortedFiles: [FileItem] {
        let files = currentFolderFiles
        let sorted: [FileItem]
        switch sortBy {
        case .name:
            sorted = files.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == (sortAscending ? .orderedAscending : .orderedDescending) }
        case .kind:
            sorted = files.sorted { lhs, rhs in
                if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        case .date:
            sorted = files.sorted { sortAscending ? ($0.createdAt > $1.createdAt) : ($0.createdAt < $1.createdAt) }
        case .size:
            sorted = files.sorted { sortAscending ? ($0.size > $1.size) : ($0.size < $1.size) }
        }
        return sorted
    }

    private var filteredFiles: [FileItem] {
        guard !searchText.isEmpty else { return sortedFiles }
        return sortedFiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer(minLength: 80)
                AppleFolderIcon(width: 68, height: 54)
                Text("No Files")
                    .font(.title2.bold())
                Text("Upload files from the Mac app to see them here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var gridView: some View {
        ScrollView {
            VStack(spacing: 0) {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ], spacing: 28) {
                    // Inline New Folder Item if creating in this folder
                    if appState.isCreatingFolder && (appState.creatingFolderParentID ?? "") == folderID {
                        InlineNewFolderGridItem(parentID: folderID, filterPrivate: filterPrivate)
                    }

                    // Folders first
                    ForEach(filteredFiles.filter(\.isFolder)) { folder in
                        if isSelecting {
                            FileGridItem(
                                file: folder,
                                isSelecting: true,
                                isSelected: selectedFileIDs.contains(folder.id)
                            ) {
                                toggleSelection(folder.id)
                            }
                        } else {
                            NavigationLink {
                                FileBrowserView(folderID: folder.id, folderTitle: folder.name, filterPrivate: filterPrivate)
                            } label: {
                                FileGridItem(file: folder)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // Files
                    ForEach(filteredFiles.filter { !$0.isFolder }) { file in
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

                // Footer
                PageItemCountFooter(count: filteredFiles.count)
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
            // Inline New Folder Row if creating in this folder
            if appState.isCreatingFolder && (appState.creatingFolderParentID ?? "") == folderID {
                InlineNewFolderRow(parentID: folderID, filterPrivate: filterPrivate)
            }

            let folders = filteredFiles.filter { $0.isFolder }
            let items = filteredFiles.filter { !$0.isFolder }

            if !folders.isEmpty {
                Section {
                    ForEach(folders) { folder in
                        if isSelecting {
                            FileRow(
                                file: folder,
                                isSelecting: true,
                                isSelected: selectedFileIDs.contains(folder.id)
                            ) {
                                toggleSelection(folder.id)
                            }
                        } else {
                            NavigationLink {
                                FileBrowserView(folderID: folder.id, folderTitle: folder.name, filterPrivate: filterPrivate)
                            } label: {
                                FileRow(file: folder)
                            }
                        }
                    }
                }
            }

            if !items.isEmpty {
                Section {
                    ForEach(items) { file in
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
                }
            }

            PageItemCountFooter(count: filteredFiles.count)
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

// MARK: - Camera Capture Picker

struct CameraMediaPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onMediaCaptured: (URL) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image", "public.movie"]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraMediaPicker

        init(_ parent: CameraMediaPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            let tempDir = (try? UploadEngine.tempDirectory()) ?? FileManager.default.temporaryDirectory

            if let videoURL = info[.mediaURL] as? URL {
                let filename = "Video_\(Int(Date().timeIntervalSince1970)).\(videoURL.pathExtension.isEmpty ? "mov" : videoURL.pathExtension)"
                let dest = tempDir.appendingPathComponent(filename)
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.copyItem(at: videoURL, to: dest)
                parent.onMediaCaptured(dest)
            } else if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                let filename = "Photo_\(Int(Date().timeIntervalSince1970)).jpg"
                let dest = tempDir.appendingPathComponent(filename)
                try? FileManager.default.removeItem(at: dest)
                try? data.write(to: dest)
                parent.onMediaCaptured(dest)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#endif
