#if os(iOS)
import SwiftUI

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
        .navigationTitle(folderTitle)
        .navigationBarTitleDisplayMode(.inline)
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
                    Menu {
                        Button {
                            isSelecting = true
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                appState.startCreatingFolder(in: folderID)
                            }
                        } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }

                        Button { } label: {
                            Label("Scan Documents", systemImage: "document.viewfinder")
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
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(.blue)
                    }
                }
            }
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
                ], spacing: 20) {
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
#endif
