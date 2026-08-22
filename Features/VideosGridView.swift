import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Google Photos-style page for the Videos destination: boxy 1:1 grid of
/// video thumbnails with duration badges, day sections with pinned headers,
/// playlist tiles (with covers + drag-drop targets). Works at the root AND
/// inside a playlist.
struct VideosGridView: View {
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

    @State private var playlistDropTargets: Set<String> = []

    private var playlists: [ObjectRecord] { files.filter(\.isFolder) }
    private var videos: [ObjectRecord] { files.filter { !$0.isFolder } }

    // Square tiles — sized like the current (good) video cards, with breathing
    // room between cards (spacing 8 instead of the old cramped 2).
    private var columns: [GridItem] {
        let minSize = max(150.0, cardWidth * 0.85)
        return [GridItem(.adaptive(minimum: minSize, maximum: cardWidth * 1.3), spacing: 8)]
    }

    /// Column count the adaptive grid actually lays out for a given width — the
    /// up/down arrow navigation steps by this many tiles, so it must match the
    /// real layout or arrows land on the wrong row (the old width/150 estimate
    /// went stale once cards grew and spacing went from 2 to 8).
    private func adaptiveColumnCount(forWidth width: CGFloat) -> Int {
        let spacing: CGFloat = 8
        let minSize = max(150.0, cardWidth * 0.85)
        return max(2, Int((width - 40 + spacing) / (minSize + spacing)))
    }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if showsCollections && !playlists.isEmpty { playlistSection }
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
        .onChange(of: videos.map(\.id).joined(separator: ",")) { _, _ in
            reportOrdered()
        }
        .onAppear {
            reportOrdered()
        }
    }

    // MARK: - Keyboard navigation support

    private var orderedIDs: [String] {
        playlists.map(\.id) + MediaGridLayout.dayGroups(videos).flatMap(\.files).map(\.id)
    }

    private func reportOrdered() {
        onOrderedChange(orderedIDs)
    }

    // MARK: - Sections

    private var playlistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Playlists")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(XTheme.textPrimary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)], spacing: 12) {
                ForEach(playlists) { playlist in
                    VideoPlaylistTile(playlist: playlist, isSelected: appState.selectedFiles.contains(playlist.id))
                        .onTapGesture(count: 2) { onOpen(playlist) }
                        .simultaneousGesture(TapGesture(count: 1).onEnded { onSelect(playlist) })
                        .contextMenu {
                            menuProvider(playlist)
                        }
                        .onDrop(of: [UTType.text], isTargeted: Binding(
                            get: { playlistDropTargets.contains(playlist.id) },
                            set: { isTarget in
                                if isTarget { playlistDropTargets.insert(playlist.id) } else { playlistDropTargets.remove(playlist.id) }
                            }
                        )) { providers in
                            MediaDragPayload.handleDrop(providers) { ids in
                                appState.moveObjects(ids: ids, to: playlist.id)
                            }
                        }
                        .overlay {
                            if playlistDropTargets.contains(playlist.id) {
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

    @ViewBuilder
    private var daySections: some View {
        ForEach(MediaGridLayout.dayGroups(videos)) { day in
            Section(header: MediaDayHeader(title: day.title)) {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(day.files) { video in
                        videoCell(video)
                    }
                }
            }
        }
    }

    private func videoCell(_ video: ObjectRecord) -> some View {
        VideoCellView(
            video: video,
            isSelected: appState.selectedFiles.contains(video.id)
        )
        .id(video.id)
        .onTapGesture(count: 2) { onOpen(video) }
        .simultaneousGesture(TapGesture(count: 1).onEnded { onSelect(video) })
        .contextMenu { menuProvider(video) }
        .onDrag { MediaDragPayload.provider(selected: appState.selectedFiles, fileID: video.id) }
    }
}

// MARK: - Playlist tile

/// Playlist tile — the cover video with up to two more frames stacked behind it.
private struct VideoPlaylistTile: View {
    let playlist: ObjectRecord
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MediaStackTile(
                collection: playlist,
                fallbackIcon: "film.stack",
                isSelected: isSelected
            )
            Text(playlist.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(XTheme.textPrimary)
                .lineLimit(1)
        }
    }
}

// MARK: - Video cell (boxy)

private struct VideoCellView: View {
    @Environment(AppState.self) private var appState
    let video: ObjectRecord
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
                if hovered {
                    Color.black.opacity(0.08)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .overlay {
                // Play glyph while hovering — clicking plays.
                if hovered {
                    Image(systemName: "play.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomLeading) {
                if hovered {
                    Text(video.name)
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
                } else if video.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Circle().fill(Color.accentColor.opacity(0.85)))
                        .padding(4)
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
            .task(id: "\(video.id)-\(appState.thumbnailVersion)") {
                thumbURL = await ThumbnailService.shared.thumbnailURL(for: video)
            }
    }

    @ViewBuilder
    private var placeholder: some View {
        Image(systemName: "film")
            .font(.system(size: 20))
            .foregroundStyle(XTheme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(XTheme.textPrimary.opacity(0.05))
    }
}