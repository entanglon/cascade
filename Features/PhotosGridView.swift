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

    @State private var people: [(PersonRecord, Int)] = []
    @State private var peopleByID: [String: PersonRecord] = [:]
    @State private var personAvatars: [String: URL] = [:]
    @State private var facesByObject: [String: [FaceRecord]] = [:]
    @State private var selectedPersonID: String?
    @State private var facesVersion = 0
    @State private var nameAlertFace: FaceRecord?
    @State private var nameDraft = ""
    @State private var showNameAlert = false
    @State private var renamePersonID: String?
    @State private var showRenameAlert = false
    @State private var coverPickerAlbum: ObjectRecord?

    private var albums: [ObjectRecord] { files.filter(\.isFolder) }
    private var photos: [ObjectRecord] { files.filter { !$0.isFolder } }

    private var columns: [GridItem] {
        let minSize = max(120.0, cardWidth * 0.75)
        return [GridItem(.adaptive(minimum: minSize, maximum: cardWidth * 1.4), spacing: 2)]
    }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if selectedPersonID == nil {
                            if showsCollections && !albums.isEmpty { albumSection }
                            if showsCollections && !people.isEmpty { peopleSection }
                        } else {
                            personHeader
                        }

                        if let pid = selectedPersonID {
                            personPhotoSection
                        } else {
                            daySections
                        }
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
            .onChange(of: Int(geo.size.width / 150)) { _, cols in
                onColumnCountChange(max(2, cols))
            }
            .onAppear {
                onColumnCountChange(max(2, Int(geo.size.width / 150)))
            }
        }
        .task(id: taskToken) { await loadFaces() }
        .onReceive(NotificationCenter.default.publisher(for: .xcPhotoIndexed)) { _ in
            facesVersion += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .xcThumbnailReady)) { _ in
            // A thumbnail landed in the background (warm-up or thumbnail-only
            // download) — re-key every cell so it picks it up.
            appState.thumbnailVersion += 1
        }
        .onChange(of: taskToken) { _, _ in reportOrdered() }
        .alert("Name this person", isPresented: $showNameAlert) {
            TextField("Name", text: $nameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveName() }
        } message: {
            Text("Faces like this will be grouped under this name.")
        }
        .alert("Rename Person", isPresented: $showRenameAlert) {
            TextField("Name", text: $nameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let pid = renamePersonID {
                    let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    Task { await FaceEngine.shared.renamePerson(pid, name: name) }
                }
            }
        }
        .sheet(item: $coverPickerAlbum) { album in
            AlbumCoverPickerSheet(album: album) { photoID in
                appState.setAlbumCover(album, photoID: photoID)
            }
        }
        .onAppear {
            selectedPersonID = nil
            reportOrdered()
        }
    }

    private var taskToken: String {
        "\(files.map(\.id).joined(separator: ","))-v\(facesVersion)"
    }

    // MARK: - Keyboard navigation support

    /// Visual order of the tiles the arrow keys walk: albums first, then the
    /// photos in day-section order (or the person's photos when filtered).
    private var orderedIDs: [String] {
        if let pid = selectedPersonID {
            return personPhotos.map(\.id)
        }
        return albums.map(\.id) + photosInDayOrder.map(\.id)
    }

    private var photosInDayOrder: [ObjectRecord] {
        MediaGridLayout.dayGroups(photos).flatMap(\.files)
    }

    private func reportOrdered() {
        onOrderedChange(orderedIDs)
    }

    // MARK: - Data

    private func loadFaces() async {
        let objectIDs = photos.map(\.id)
        facesByObject = await FaceEngine.shared.facesByObject(for: objectIDs)
        let loaded = await FaceEngine.shared.people()
        people = loaded
        peopleByID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.0.id, $0.0) })
        var avatars: [String: URL] = [:]
        for (person, _) in loaded {
            if let url = await FaceEngine.shared.personAvatarURL(person.id) {
                avatars[person.id] = url
            }
        }
        personAvatars = avatars
        reportOrdered()
    }

    private func saveName() {
        guard let face = nameAlertFace else { return }
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            await FaceEngine.shared.nameFace(face.id, name: name)
        }
        nameDraft = ""
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

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("People")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(XTheme.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(people, id: \.0.id) { person, count in
                        Button {
                            selectedPersonID = person.id
                        } label: {
                            VStack(spacing: 6) {
                                PersonAvatarView(url: personAvatars[person.id], size: 56)
                                    .overlay {
                                        Circle().strokeBorder(XTheme.textSecondary.opacity(0.3), lineWidth: 1)
                                    }
                                Text(person.name)
                                    .font(.system(size: 11))
                                    .foregroundStyle(XTheme.textPrimary)
                                Text("\(count)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(XTheme.textSecondary)
                            }
                            .frame(width: 76)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                renamePersonID = person.id
                                nameDraft = person.name
                                showRenameAlert = true
                            } label: {
                                Label("Rename Person", systemImage: "pencil")
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.bottom, 22)
    }

    private var personHeader: some View {
        HStack(spacing: 12) {
            Button {
                selectedPersonID = nil
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.backward")
                    Text("All Photos")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(XTheme.textSecondary)
            }
            .buttonStyle(.plain)

            if let pid = selectedPersonID {
                PersonAvatarView(url: personAvatars[pid], size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(peopleByID[pid]?.name ?? "Person")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(XTheme.textPrimary)
                    Text("\(personPhotoIDs.count) photos")
                        .font(.system(size: 11))
                        .foregroundStyle(XTheme.textSecondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var daySections: some View {
        ForEach(MediaGridLayout.dayGroups(photos)) { day in
            Section(header: MediaDayHeader(title: day.title)) {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(day.files) { photo in
                        photoCell(photo)
                    }
                }
            }
        }
    }

    private var personPhotoSection: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(personPhotos) { photo in
                photoCell(photo)
            }
        }
    }

    private func photoCell(_ photo: ObjectRecord) -> some View {
        PhotoCellView(
            photo: photo,
            isSelected: appState.selectedFiles.contains(photo.id),
            faces: facesByObject[photo.id] ?? [],
            peopleByID: peopleByID,
            onFaceTap: { face in handleFaceTap(face) }
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

    private func handleFaceTap(_ face: FaceRecord) {
        if let pid = face.personID, peopleByID[pid] != nil {
            selectedPersonID = pid
        } else {
            nameAlertFace = face
            nameDraft = ""
            showNameAlert = true
        }
    }

    // MARK: - Person filter

    private var personPhotoIDs: Set<String> {
        guard let pid = selectedPersonID else { return [] }
        return Set(facesByObject.filter { _, faces in
            faces.contains { $0.personID == pid }
        }.keys)
    }

    private var personPhotos: [ObjectRecord] {
        let ids = personPhotoIDs
        return photos.filter { ids.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
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
    let faces: [FaceRecord]
    let peopleByID: [String: PersonRecord]
    let onFaceTap: (FaceRecord) -> Void

    @State private var thumbURL: URL?
    @State private var hovered = false
    @State private var faceThumbs: [FaceRecord: URL] = [:]

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
            .overlay(alignment: .topLeading) {
                if hovered {
                    faceChips
                        .padding(6)
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
            .task(id: faces.map(\.id).joined(separator: ",")) {
                var map: [FaceRecord: URL] = [:]
                for face in faces {
                    if let url = await FaceEngine.shared.faceThumbURL(objectID: face.objectID, faceID: face.id) {
                        map[face] = url
                    }
                }
                faceThumbs = map
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

    @ViewBuilder
    private var faceChips: some View {
        let visible = Array(faces.prefix(3))
        HStack(spacing: 4) {
            ForEach(visible, id: \.id) { face in
                Button {
                    onFaceTap(face)
                } label: {
                    ZStack {
                        Circle().fill(.white.opacity(0.85))
                        if let url = faceThumbs[face] {
                            AsyncImage(url: url) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().scaledToFill()
                                }
                            }
                            .clipShape(Circle())
                        } else {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(XTheme.textSecondary)
                        }
                    }
                    .frame(width: 20, height: 20)
                    .shadow(radius: 1)
                }
                .buttonStyle(.plain)
                .help(faceName(face))
            }
            if faces.count > 3 {
                Text("+\(faces.count - 3)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
            }
        }
    }

    private func faceName(_ face: FaceRecord) -> String {
        guard let pid = face.personID, let person = peopleByID[pid] else { return "Name this person…" }
        return person.name
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

// MARK: - Person avatar

private struct PersonAvatarView: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: size * 0.5))
                            .foregroundStyle(XTheme.textSecondary)
                    }
                }
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(XTheme.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .background(XTheme.textPrimary.opacity(0.08))
        .clipShape(Circle())
    }
}