#if os(iOS)
import SwiftUI

struct FileBrowserView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            Group {
                if appState.isLoadingFiles && appState.files.isEmpty {
                    ProgressView("Loading files…")
                } else if appState.files.isEmpty {
                    emptyState
                } else {
                    fileList
                }
            }
            .navigationTitle(appState.currentFolderName)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if appState.canNavigateBack {
                        Button {
                            appState.navigateBack()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text(backButtonTitle)
                            }
                        }
                    }
                }
            }
            .refreshable {
                await appState.loadAllFiles()
            }
        }
    }

    private var backButtonTitle: String {
        if appState.folderStack.count >= 2 {
            return appState.folderStack[appState.folderStack.count - 2].name
        }
        return "Back"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 48))
                .foregroundStyle(.blue.opacity(0.6))
            Text("No files")
                .font(.headline)
            Text("Upload files from the Mac app to see them here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var fileList: some View {
        List {
            // Folders first
            let folders = appState.files.filter { $0.isFolder }
            let items = appState.files.filter { !$0.isFolder }

            if !folders.isEmpty {
                Section {
                    ForEach(folders) { file in
                        FileRow(file: file) {
                            appState.navigateToFolder(file)
                        }
                    }
                } header: {
                    Text("Folders")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !items.isEmpty {
                Section {
                    ForEach(items) { file in
                        FileRow(file: file) {
                            if file.isVideo {
                                appState.openTheater(file)
                            }
                        }
                    }
                } header: {
                    if !folders.isEmpty {
                        Text("Files")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - File Row (Files-app style)

private struct FileRow: View {
    let file: FileItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Icon / Thumbnail
                if let thumbData = file.thumbnailData, let img = UIImage(data: thumbData) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(file.iconColor.opacity(0.15))
                            .frame(width: 44, height: 44)
                        Image(systemName: file.systemIcon)
                            .font(.system(size: 18))
                            .foregroundStyle(file.iconColor)
                    }
                }

                // Name + meta
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    if !file.isFolder {
                        HStack(spacing: 4) {
                            if let size = file.formattedSize {
                                Text(size)
                            }
                            Text("•")
                            Text(file.createdAt, style: .relative)
                        }
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                if file.isFolder {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
#endif
