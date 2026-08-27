#if os(iOS)
import SwiftUI
import os

struct FileBrowserView: View {
    @Environment(AppState.self) private var appState
    @State private var viewMode: ViewMode = .grid
    @State private var showImportPicker = false

    enum ViewMode {
        case grid, list
    }

    var body: some View {
        NavigationStack {
            Group {
                if appState.files.isEmpty && !appState.isLoadingFiles {
                    emptyState
                } else {
                    contentView
                }
            }
            .navigationTitle(appState.currentFolderName)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            viewMode = viewMode == .grid ? .list : .grid
                        } label: {
                            Label(viewMode == .grid ? "List View" : "Grid View",
                                  systemImage: viewMode == .grid ? "list.bullet" : "square.grid.2x2")
                        }

                        Button {
                            showImportPicker = true
                        } label: {
                            Label("Import Files", systemImage: "plus.circle")
                        }

                        Button {
                            Task { await appState.loadFiles() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("No files yet")
                .font(.title2.bold())
            Text("Import files or upload from your vault to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Import Files") { showImportPicker = true }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    @ViewBuilder
    private var contentView: some View {
        switch viewMode {
        case .grid:
            gridView
        case .list:
            listView
        }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                ForEach(appState.files) { file in
                    FileGridCard(file: file) {
                        handleTap(file)
                    }
                }
            }
            .padding()
        }
        .refreshable { await appState.loadFiles() }
    }

    private var listView: some View {
        List {
            ForEach(appState.files) { file in
                FileListRow(file: file) {
                    handleTap(file)
                }
            }
        }
        .refreshable { await appState.loadFiles() }
        .listStyle(.plain)
    }

    private func handleTap(_ file: FileItem) {
        if file.isFolder {
            appState.navigateToFolder(file)
        } else if file.isVideo {
            appState.openTheater(file)
        }
    }
}

// MARK: - Grid Card

private struct FileGridCard: View {
    let file: FileItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                if let thumbData = file.thumbnailData,
                   let img = UIImage(data: thumbData) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .frame(height: 100)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 100)
                        .overlay {
                            Image(systemName: file.isFolder ? "folder.fill" : file.systemIcon)
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                }

                VStack(spacing: 2) {
                    Text(file.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)

                    if !file.isFolder, let size = file.formattedSize {
                        Text(size)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - List Row

private struct FileListRow: View {
    let file: FileItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if let thumbData = file.thumbnailData,
                   let img = UIImage(data: thumbData) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: file.isFolder ? "folder.fill" : file.systemIcon)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    if !file.isFolder, let size = file.formattedSize {
                        Text(size)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if file.isFolder {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
#endif
