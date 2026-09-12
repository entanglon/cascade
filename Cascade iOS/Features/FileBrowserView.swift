#if os(iOS)
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct FileBrowserView: View {
    @Environment(AppState.self) private var appState
    var folderID: String = ""
    var folderTitle: String = "All Files"
    var filterPrivate: Bool = false

    @State private var searchText = ""
    @State private var viewMode: ViewMode = .grid
    @State private var sortBy: SortOption = .name
    @State private var sortAscending = true
    @State private var viewportHeight: CGFloat = 0

    @State private var isSelecting = false
    @State private var selectedFileIDs: Set<String> = []

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
        ZStack {
            Color(red: 0.05, green: 0.06, blue: 0.08)
                .ignoresSafeArea()

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
        .navigationBarTitleDisplayMode(isSelecting ? .inline : .large)
        .navigationBarBackButtonHidden(isSelecting)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: isSelecting ? .automatic : .always), prompt: "Search")
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
                    HStack(spacing: 12) {
                        StandardAddMenu(folderID: folderID.isEmpty ? nil : folderID, isPrivate: filterPrivate)

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
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBottomBar
            }
        }
        .onChange(of: isSelecting) { _, new in
            appState.isSelecting = new
        }
        .onDisappear {
            if isSelecting {
                isSelecting = false
                appState.isSelecting = false
            }
        }
        .refreshable {
            await appState.loadAllFiles()
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
        .padding(.horizontal, 44)
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
        VStack(spacing: 16) {
            Spacer()
            AppleFolderIcon(width: 68, height: 54)
            Text("No Files")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("Upload files from the Mac app or tap + to add files.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var gridView: some View {
        ScrollView {
            VStack(spacing: 0) {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16, alignment: .top),
                    GridItem(.flexible(), spacing: 16, alignment: .top),
                    GridItem(.flexible(), spacing: 16, alignment: .top)
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
