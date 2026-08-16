import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Google/Apple Photos-style browsing for the Photos destination: boxy 1:1
/// grid with near-zero gaps, day sections with pinned (floating) date headers,
/// album tiles (with covers, drag-and-drop targets), a People chip row, and
/// per-photo face chips for naming. Works at the root AND inside an album.
struct PhotosGridView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("xc.cardWidth") private var cardWidth = 200.0

    let files: [ObjectRecord]
    let showsCollections: Bool
    let onOpen: (ObjectRecord) -> Void
    let onSelect: (ObjectRecord) -> Void
    let menuProvider: (ObjectRecord) -> AnyView
    let onOrderedChange: ([String]) -> Void
    let onColumnCountChange: (Int) -> Void
    @Binding var scrollTargetID: String?

    @State private var coverPickerAlbum: ObjectRecord?

    private var albums: [ObjectRecord] { files.filter(\.isFolder) }
    private var photos: [ObjectRecord] { files.filter { !$0.isFolder } }

    // Square tiles — a bit larger than before, with breathing room between
    // cards (spacing 8 instead of the old cramped 2).
    private var columns: [GridItem] {
        let minSize = max(160.0, cardWidth * 0.9)
        return [GridItem(.adaptive(minimum: minSize, maximum: cardWidth * 1.5), spacing: 8)]
    }

    /// Column count the adaptive grid actually lays out for a given width — the
    /// up/down arrow navigation steps by this many tiles, so it must match the
    /// real layout or arrows land on the wrong row (the old width/150 estimate
    /// went stale once cards grew and spacing went from 2 to 8).
    private func adaptiveColumnCount(forWidth width: CGFloat) -> Int {
        let spacing: CGFloat = 8
        let minSize = max(160.0, cardWidth * 0.9)
        return max(2, Int((width - 40 + spacing) / (minSize + spacing)))
    }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if showsCollections && !albums.isEmpty { albumSection }
                        daySections
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 80)
                }
                .onChange(of: scrollTargetID) { _, newID in
                    guard let newID else { return }
                    proxy.scrollTo(newID, anchor: nil)
                }
            }
            .onChange(of: adaptiveColumnCount(forWidth: geo.size.width)) { _, cols in
                onColumnCountChange(cols)
            }
            .onAppear {
                onColumnCountChange(adaptiveColumnCount(forWidth: geo.size.width))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .xcThumbnailReady)) { _ in
            // A thumbnail landed in the background (warm-up or thumbnail-only
            // download) — re-key every cell so it picks it up.
            appState.thumbnailVersion += 1
        }
        .onChange(of: files.map(\.id)) { _, _ in reportOrdered() }
        .sheet(item: $coverPickerAlbum) { album in
            AlbumCoverPickerSheet(album: album) { photoID in
                appState.setAlbumCover(album, photoID: photoID)
            }
        }
        .onAppear {
            reportOrdered()
        }
    }

    // MARK: - Keyboard navigation support

    /// Visual order of the tiles the arrow keys walk: albums first, then the
    /// photos in day-section order.
    private var orderedIDs: [String] {
        albums.map(\.id) + photosInDayOrder.map(\.id)
    }

    private var photosInDayOrder: [ObjectRecord] {
        MediaGridLayout.dayGroups(photos).flatMap(\.files)
    }

    private func reportOrdered() {
        onOrderedChange(orderedIDs)
    }

    // MARK: - Sections

    private var albumSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Albums")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(XTheme.textPrimary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)], spacing: 12) {
                ForEach(albums) { album in
                    PhotoAlbumTile(album: album, isSelected: appState.selectedFiles.contains(album.id))
                        .onTapGesture(count: 2) { onOpen(album) }
                        .simultaneousGesture(TapGesture(count: 1).onEnded { onSelect(album) })
                        .contextMenu {
                            menuProvider(album)
                            Divider()
                            Button {
                                coverPickerAlbum = album
                            } label: {
                                Label("Set Album Cover…", systemImage: "photo.badge.checkmark")
                            }
                        }
                        .onDrop(of: [UTType.text], isTargeted: Binding(
                            get: { albumDropTargets.contains(album.id) },
                            set: { isTarget in
                                if isTarget { albumDropTargets.insert(album.id) } else { albumDropTargets.remove(album.id) }
                            }
                        )) { providers in
                            MediaDragPayload.handleDrop(providers) { ids in
                                appState.moveObjects(ids: ids, to: album.id)
                            }
                        }
                        .overlay {
                            if albumDropTargets.contains(album.id) {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.accentColor, lineWidth: 3)
                                    .padding(-3)
                            }
                        }
                }
            }
        }
        .padding(.bottom, 22)
    }

    @State private var albumDropTargets: Set<String> = []

    @ViewBuilder
    private var daySections: some View {
        ForEach(MediaGridLayout.dayGroups(photos)) { day in
            Section(header: MediaDayHeader(title: day.title)) {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(day.files) { photo in
                        photoCell(photo)
                    }
                }
            }
        }
    }

    private func photoCell(_ photo: ObjectRecord) -> some View {
        PhotoCellView(
            photo: photo,
            isSelected: appState.selectedFiles.contains(photo.id)
        )
        .id(photo.id)
        .onTapGesture(count: 2) { onOpen(photo) }
        .simultaneousGesture(TapGesture(count: 1).onEnded { onSelect(photo) })
        .contextMenu {
            menuProvider(photo)
            if let album = albums.first(where: { $0.id == appState.currentFolderID }) {
                Divider()
                Button {
                    appState.setAlbumCover(album, photoID: photo.id)
                } label: {
                    Label("Set as Album Cover", systemImage: "photo.badge.checkmark")
                }
            }
        }
        .onDrag { MediaDragPayload.provider(selected: appState.selectedFiles, fileID: photo.id) }
    }

}

// MARK: - Album tile (cover + drag-drop target)

/// Album tile — the cover photo with up to two more photos stacked behind it.
private struct PhotoAlbumTile: View {
    let album: ObjectRecord
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MediaStackTile(
                collection: album,
                fallbackIcon: "photo.on.rectangle.angled",
                isSelected: isSelected
            )
            Text(album.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(XTheme.textPrimary)
                .lineLimit(1)
        }
    }
}

// MARK: - Photo cell (boxy)

private struct PhotoCellView: View {
    @Environment(AppState.self) private var appState
    let photo: ObjectRecord
    let isSelected: Bool

    @State private var thumbURL: URL?
    @State private var hovered = false

    var body: some View {
        Color.black.opacity(0.04)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let thumbURL {
                    AsyncImage(url: thumbURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                                .scaleEffect(hovered ? 1.06 : 1.0)
                                .animation(.easeOut(duration: 0.2), value: hovered)
                        case .failure:
                            placeholder
                        default:
                            ProgressView().controlSize(.small)
                        }
                    }
                } else {
                    placeholder
                }
            }
            .clipped()
            .overlay {
                // Slight dim + gradient veil while hovering so the name/faces read.
                if hovered {
                    Color.black.opacity(0.08)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if hovered {
                    Text(photo.name)
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
                        .padding(6)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.accentColor, .white)
                        .padding(5)
                }
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .animation(.easeOut(duration: 0.15), value: hovered)
            .onHover { hovering in
                hovered = hovering
            }
            .task(id: photo.id) {
                thumbURL = await ThumbnailService.shared.thumbnailURL(for: photo)
            }
    }

    @ViewBuilder
    private var placeholder: some View {
        Image(systemName: "photo")
            .font(.system(size: 20))
            .foregroundStyle(XTheme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(XTheme.textPrimary.opacity(0.05))
    }

}

// MARK: - Album cover picker

private struct AlbumCoverPickerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let album: ObjectRecord
    let onPick: (String?) -> Void

    private var contents: [ObjectRecord] {
        appState.files
            .filter { $0.parentID == album.id && !$0.trashed && !$0.isFolder }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Set Album Cover")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            if contents.isEmpty {
                Text("This album has no photos yet — move photos into it first.")
                    .font(.system(size: 13))
                    .foregroundStyle(XTheme.textSecondary)
                    .padding(40)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(contents) { photo in
                            CoverOptionCell(
                                photo: photo,
                                isCurrent: album.coverObjectID == photo.id
                            ) {
                                onPick(photo.id)
                                dismiss()
                            }
                        }
                    }
                    .padding(16)
                }
            }

            Divider()
            HStack {
                Button("Remove Cover", role: .destructive) {
                    onPick(nil)
                    dismiss()
                }
                .disabled(album.coverObjectID == nil)
                Spacer()
            }
            .padding(12)
        }
        .frame(width: 520, height: 460)
    }
}

private struct CoverOptionCell: View {
    let photo: ObjectRecord
    let isCurrent: Bool
    let onTap: () -> Void

    @State private var thumbURL: URL?

    var body: some View {
        Button {
            onTap()
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(XTheme.textPrimary.opacity(0.08))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let thumbURL {
                            AsyncImage(url: thumbURL) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().scaledToFill()
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .overlay {
                        if isCurrent {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(Color.accentColor, .white)
                                        .padding(4)
                                }
                        }
                    }
                Text(photo.name)
                    .font(.system(size: 10))
                    .foregroundStyle(XTheme.textSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .task(id: photo.id) {
            thumbURL = await ThumbnailService.shared.thumbnailURL(for: photo)
        }
    }
}
