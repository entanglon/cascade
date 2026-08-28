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
            if appState.isLoadingFiles && currentFolderFiles.isEmpty {
                ProgressView("Loading files…")
            } else if filteredFiles.isEmpty {
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
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { } label: {
                        Label("Select", systemImage: "checkmark.circle")
                    }
                    Button { } label: {
                        Label("Scan Documents", systemImage: "document.viewfinder")
                    }
                    Button { } label: {
                        Label("Connect to Server", systemImage: "desktopcomputer")
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
        .refreshable {
            await appState.loadAllFiles()
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
        let files = sortedFiles
        guard !searchText.isEmpty else { return files }
        return files.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "folder")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("No Files")
                .font(.title2.bold())
            Text("Upload files from the Mac app to see them here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
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
                    // Folders first
                    ForEach(filteredFiles.filter(\.isFolder)) { folder in
                        NavigationLink {
                            FileBrowserView(folderID: folder.id, folderTitle: folder.name, filterPrivate: filterPrivate)
                        } label: {
                            FileGridItem(file: folder)
                        }
                        .buttonStyle(.plain)
                    }
                    // Files
                    ForEach(filteredFiles.filter { !$0.isFolder }) { file in
                        FileGridItem(file: file) {
                            appState.openFile(file)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer(minLength: 40)

                // Footer
                VStack(spacing: 4) {
                    Text("\(filteredFiles.count) \(filteredFiles.count == 1 ? "item" : "items")")
                        .font(.subheadline.bold())
                    if appState.isVaultConnected {
                        Text("Synced with Cascade")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var listView: some View {
        List {
            let folders = filteredFiles.filter { $0.isFolder }
            let items = filteredFiles.filter { !$0.isFolder }

            if !folders.isEmpty {
                Section {
                    ForEach(folders) { folder in
                        NavigationLink {
                            FileBrowserView(folderID: folder.id, folderTitle: folder.name, filterPrivate: filterPrivate)
                        } label: {
                            FileRow(file: folder)
                        }
                    }
                }
            }

            if !items.isEmpty {
                Section {
                    ForEach(items) { file in
                        FileRow(file: file) {
                            appState.openFile(file)
                        }
                    }
                }
            }

            Section {
            } footer: {
                VStack(spacing: 4) {
                    Text("\(filteredFiles.count) \(filteredFiles.count == 1 ? "item" : "items")")
                        .font(.subheadline.bold())
                    if appState.isVaultConnected {
                        Text("Synced with Cascade")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
            }
        }
        .listStyle(.plain)
    }
}
#endif
