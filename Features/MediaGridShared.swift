import SwiftUI
import UniformTypeIdentifiers

/// Shared building blocks for the Photos and Videos pages (Google/Apple Photos
/// style): boxy grids, day sections with pinned floating date pills, and the
/// drag payload used to move files into albums/playlists.

struct MediaDayGroup: Identifiable {
    let id: Date
    let title: String
    let files: [ObjectRecord]
}

enum MediaGridLayout {
    /// Groups files by calendar day (newest day first, within a day oldest
    /// first) with Google-Photos-style headers.
    static func dayGroups(_ files: [ObjectRecord]) -> [MediaDayGroup] {
        let cal = Calendar.current
        var grouped: [Date: [ObjectRecord]] = [:]
        for f in files {
            let day = cal.startOfDay(for: f.createdAt)
            grouped[day, default: []].append(f)
        }
        return grouped.sorted { $0.key > $1.key }.map { day, items in
            MediaDayGroup(
                id: day,
                title: dayTitle(day),
                files: items.sorted { $0.createdAt < $1.createdAt }
            )
        }
    }

    static func dayTitle(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.locale = .current
        if cal.component(.year, from: date) == cal.component(.year, from: Date()) {
            fmt.dateFormat = "EEEE, MMMM d"
        } else {
            fmt.dateFormat = "EEEE, MMMM d, yyyy"
        }
        return fmt.string(from: date)
    }
}


/// The pinned day pill that sticks to the top while scrolling a day section.
struct MediaDayHeader: View {
    let title: String
    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(XTheme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(XTheme.textPrimary.opacity(0.08), lineWidth: 1))
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

/// Layered album/playlist tile — the Google-Photos-style "stack of photos"
/// look. The cover (or newest photo) fills the tile; up to two more photos peek
/// out behind its top-left edge, drawn slightly LARGER than the front so their
/// edges show through the clip (a same-size card behind a full-bleed front would
/// be entirely hidden). Falls back to a placeholder icon when the collection is
/// empty.
struct MediaStackTile: View {
    @Environment(AppState.self) private var appState
    let collection: ObjectRecord        // album or playlist folder
    let fallbackIcon: String
    let isSelected: Bool

    @State private var frontURL: URL?
    @State private var backURLs: [URL] = []

    private var childPhotos: [ObjectRecord] {
        appState.files
            .filter { $0.parentID == collection.id && !$0.trashed && !$0.isFolder }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private var itemCount: Int { childPhotos.count }

    /// Cover photo first (when set), then the rest of the album in upload order.
    private var orderedPhotos: [ObjectRecord] {
        if let coverID = collection.coverObjectID,
           let cover = childPhotos.first(where: { $0.id == coverID }) {
            return [cover] + childPhotos.filter { $0.id != coverID }
        }
        return childPhotos
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(XTheme.textPrimary.opacity(0.08))
            .aspectRatio(1, contentMode: .fit)
            .overlay { stack }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottomTrailing) {
                Text("\(itemCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(6)
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                }
            }
            .task(id: "\(collection.id)-\(collection.coverObjectID ?? "")-\(appState.thumbnailVersion)") {
                await loadThumbs()
            }
    }

    private func loadThumbs() async {
        let photos = orderedPhotos
        guard let first = photos.first else {
            frontURL = nil
            backURLs = []
            return
        }
        frontURL = await ThumbnailService.shared.thumbnailURL(for: first)
        backURLs = []
        for photo in photos.dropFirst().prefix(2) {
            if let url = await ThumbnailService.shared.thumbnailURL(for: photo) {
                backURLs.append(url)
            }
        }
    }

    @ViewBuilder
    private var stack: some View {
        GeometryReader { geo in
            let side = geo.size.width
            ZStack {
                // Deepest back — largest, offset up-left so its edges peek through.
                if backURLs.count >= 2 {
                    layer(backURLs[1])
                        .frame(width: side * 1.12, height: side * 1.12)
                        .offset(x: -10, y: -8)
                        .zIndex(0)
                }
                if let url = backURLs.first {
                    layer(url)
                        .frame(width: side * 1.06, height: side * 1.06)
                        .offset(x: -4, y: -3)
                        .zIndex(1)
                }
                // Front card — full tile on top.
                Group {
                    if let frontURL {
                        layer(frontURL)
                    } else {
                        Image(systemName: fallbackIcon)
                            .font(.system(size: 28))
                            .foregroundStyle(XTheme.textSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(XTheme.textPrimary.opacity(0.05))
                    }
                }
                .frame(width: side, height: side)
                .zIndex(2)
            }
        }
    }

    private func layer(_ url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Color.black.opacity(0.25)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }
}

enum MediaDragPayload {
    /// Files are dragged as a newline-separated list of object IDs.
    static func provider(selected: Set<String>, fileID: String) -> NSItemProvider {
        let ids = selected.contains(fileID) ? Array(selected) : [fileID]
        return NSItemProvider(object: ids.joined(separator: "\n") as NSString)
    }

    /// Parses the dropped payload into object IDs.
    static func parseObjectIDs(_ object: NSString?) -> [String] {
        guard let object else { return [] }
        return (object as String)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Resolves dropped providers into object IDs and runs the action.
    static func handleDrop(_ providers: [NSItemProvider], action: @escaping ([String]) -> Void) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                let ids = parseObjectIDs(object as? NSString)
                guard !ids.isEmpty else { return }
                Task { @MainActor in
                    action(ids)
                }
            }
            handled = true
        }
        return handled
    }
}
