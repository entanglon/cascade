import SwiftUI

struct NotesView: View {
    @Environment(AppState.self) private var appState

    @AppStorage("xc.viewMode") private var viewModeRaw = "grid"
    @AppStorage("xc.cardWidth") private var cardWidth = 200.0

    @State private var selectedNoteIDs: Set<String> = []
    @FocusState private var isNotesFocused: Bool
    @State private var columnCount = 4

    private static let colorMap: [String: Color] = [
        "amber": Color(red: 0.95, green: 0.75, blue: 0.25),
        "emerald": Color(red: 0.25, green: 0.78, blue: 0.55),
        "cyan": Color(red: 0.30, green: 0.72, blue: 0.90),
        "purple": Color(red: 0.65, green: 0.45, blue: 0.90),
        "rose": Color(red: 0.95, green: 0.40, blue: 0.55),
        "slate": Color(red: 0.45, green: 0.55, blue: 0.68),
        "dark": Color.white.opacity(0.12)
    ]

    private var filteredNotes: [NoteRecord] {
        let active = appState.notes.filter { !$0.trashed }
        let query = appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return active }
        return active.filter {
            $0.title.lowercased().contains(query) ||
            $0.content.lowercased().contains(query) ||
            $0.tags.lowercased().contains(query)
        }
    }

    private var pinnedNotes: [NoteRecord] {
        filteredNotes.filter { $0.isPinned }
    }

    private var otherNotes: [NoteRecord] {
        filteredNotes.filter { !$0.isPinned }
    }

    private var selectedNote: NoteRecord? {
        filteredNotes.first { selectedNoteIDs.contains($0.id) }
    }

    var body: some View {
        ZStack {
            if filteredNotes.isEmpty {
                emptyNotesView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Pinned Notes Section
                        if !pinnedNotes.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 6) {
                                    Image(systemName: "pin.fill")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(XTheme.accent)
                                    Text("PINNED")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.5))
                                    Spacer()
                                }

                                if viewModeRaw == "list" {
                                    notesList(pinnedNotes)
                                } else {
                                    notesGrid(pinnedNotes)
                                }
                            }
                        }

                        // Other Notes Section
                        if !otherNotes.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                if !pinnedNotes.isEmpty {
                                    HStack(spacing: 6) {
                                        Text("OTHERS")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(.white.opacity(0.5))
                                        Spacer()
                                    }
                                }

                                if viewModeRaw == "list" {
                                    notesList(otherNotes)
                                } else {
                                    notesGrid(otherNotes)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 80)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedNoteIDs.removeAll()
        }
        .contextMenu {
            Button("New Note") {
                appState.createNewNoteDraft()
            }
            Button("Select All") {
                selectedNoteIDs = Set(filteredNotes.map { $0.id })
            }
            if !selectedNoteIDs.isEmpty {
                Divider()
                Button("Move to Trash", role: .destructive) {
                    deleteSelectedNotes()
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isNotesFocused)
        .onKeyPress(.delete) {
            deleteSelectedNotes()
            return .handled
        }
        .onKeyPress(.escape) {
            selectedNoteIDs.removeAll()
            return .handled
        }
        .onKeyPress("a", phases: .down) { press in
            if press.modifiers.contains(.command) {
                selectedNoteIDs = Set(filteredNotes.map { $0.id })
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.return) {
            if let note = selectedNote {
                appState.editingNote = note
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.space) {
            if let note = selectedNote {
                appState.editingNote = note
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.downArrow, phases: .down) { press in
            keyNav(1, isVertical: true)
            return .handled
        }
        .onKeyPress(.upArrow, phases: .down) { press in
            keyNav(-1, isVertical: true)
            return .handled
        }
        .onKeyPress(.leftArrow) { keyNav(-1, isVertical: false); return .handled }
        .onKeyPress(.rightArrow) { keyNav(1, isVertical: false); return .handled }
        .onAppear {
            isNotesFocused = true
        }
        .sheet(item: Bindable(appState).editingNote) { note in
            NoteEditorSheet(note: note)
                .environment(appState)
        }
        .background {
            // Reliable key handling regardless of SwiftUI focus: local NSEvent
            // monitor (same mechanism TheaterView / MiniPlayerView use).
            NotesKeyMonitorView(
                shouldDefer: {
                    appState.editingNote != nil || appState.theaterFile != nil || AudioPlayerEngine.shared.isFullScreen
                },
                onDelete: { deleteSelectedNotes() },
                onEscape: { selectedNoteIDs.removeAll() },
                onArrow: { delta, isVertical in keyNav(delta, isVertical: isVertical) },
                onSpace: { openSelectedNote() },
                onReturn: { openSelectedNote() },
                onCmdA: { selectedNoteIDs = Set(filteredNotes.map { $0.id }) },
                onCmdN: { appState.createNewNoteDraft() }
            )
            .frame(width: 0, height: 0)
        }
    }

    private func openSelectedNote() {
        guard let note = selectedNote else { return }
        appState.editingNote = note
    }

    // MARK: - Grid View

    private func notesGrid(_ notes: [NoteRecord]) -> some View {
        GeometryReader { geo in
            let cols = max(2, Int(geo.size.width / cardWidth))
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cols),
                spacing: 12
            ) {
                ForEach(notes) { note in
                    NoteCardView(note: note, isSelected: selectedNoteIDs.contains(note.id))
                        .onTapGesture(count: 2) {
                            appState.editingNote = note
                        }
                        .simultaneousGesture(TapGesture(count: 1).onEnded {
                            selectNote(note)
                        })
                        .onDrag {
                            noteDragPayload(note)
                        }
                        .contextMenu {
                            noteContextMenu(note)
                        }
                }
            }
            .onChange(of: geo.size.width, initial: true) {
                columnCount = max(2, Int(geo.size.width / cardWidth))
            }
        }
        .frame(minHeight: CGFloat(max(1, (notes.count + columnCount - 1) / columnCount)) * 140.0)
    }

    // MARK: - List View

    private func notesList(_ notes: [NoteRecord]) -> some View {
        LazyVStack(spacing: 4) {
            ForEach(notes) { note in
                NoteListRow(note: note, isSelected: selectedNoteIDs.contains(note.id))
                    .onTapGesture(count: 2) {
                        appState.editingNote = note
                    }
                    .simultaneousGesture(TapGesture(count: 1).onEnded {
                        selectNote(note)
                    })
                    .onDrag {
                        noteDragPayload(note)
                    }
                    .contextMenu {
                        noteContextMenu(note)
                    }
            }
        }
    }

    // MARK: - Selection & Key Nav

    private func selectNote(_ note: NoteRecord) {
        let isCmd = NSEvent.modifierFlags.contains(.command)
        if isCmd {
            if selectedNoteIDs.contains(note.id) {
                selectedNoteIDs.remove(note.id)
            } else {
                selectedNoteIDs.insert(note.id)
            }
        } else {
            selectedNoteIDs = [note.id]
        }
    }

    private func keyNav(_ delta: Int, isVertical: Bool) {
        let notes = filteredNotes
        guard !notes.isEmpty else { return }
        let currentIdx = notes.firstIndex { selectedNoteIDs.contains($0.id) }
        // In list view rows are linear; only the grid moves in column steps.
        let step = isVertical ? (viewModeRaw == "list" ? delta : delta * columnCount) : delta
        let nextIdx: Int
        if let currentIdx {
            nextIdx = min(max(currentIdx + step, 0), notes.count - 1)
        } else {
            nextIdx = delta > 0 ? 0 : notes.count - 1
        }
        selectedNoteIDs = [notes[nextIdx].id]
    }

    private func deleteSelectedNotes() {
        guard !selectedNoteIDs.isEmpty else { return }
        let toTrash = filteredNotes.filter { selectedNoteIDs.contains($0.id) }
        for note in toTrash {
            appState.trashNote(note)
        }
        selectedNoteIDs.removeAll()
    }

    // MARK: - Multi-Selection Helpers

    /// Finder-style: dragging a note that's part of a multi-selection drags the
    /// whole selection (newline-joined IDs, same payload the sidebar Trash parses).
    private func noteDragPayload(_ note: NoteRecord) -> NSItemProvider {
        if selectedNoteIDs.contains(note.id) && selectedNoteIDs.count > 1 {
            return NSItemProvider(object: selectedNoteIDs.sorted().joined(separator: "\n") as NSString)
        }
        return NSItemProvider(object: note.id as NSString)
    }

    /// The notes a context-menu action applies to: the whole selection when the
    /// right-clicked note is part of a multi-selection, otherwise just that note.
    private func contextTargets(_ note: NoteRecord) -> [NoteRecord] {
        if selectedNoteIDs.contains(note.id) && selectedNoteIDs.count > 1 {
            return filteredNotes.filter { selectedNoteIDs.contains($0.id) }
        }
        return [note]
    }

    @ViewBuilder
    private func noteContextMenu(_ note: NoteRecord) -> some View {
        let targets = contextTargets(note)
        let pinLabel = targets.count > 1
            ? (note.isPinned ? "Unpin \(targets.count) Notes" : "Pin \(targets.count) Notes")
            : (note.isPinned ? "Unpin Note" : "Pin Note")
        Button(pinLabel) {
            for target in targets { appState.togglePinNote(target) }
        }
        if targets.count == 1 {
            Button("Edit Note") {
                appState.editingNote = note
            }
        }
        Divider()
        Button(targets.count > 1 ? "Move \(targets.count) Notes to Trash" : "Move to Trash", role: .destructive) {
            for target in targets { appState.trashNote(target) }
            selectedNoteIDs.subtract(targets.map { $0.id })
        }
    }

    // MARK: - Empty View

    private var emptyNotesView: some View {
        VStack(spacing: 16) {
            Image(systemName: "note.text")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(XTheme.brandGradient)

            Text("No Notes Yet")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)

            Text("Click the + button below to create your first encrypted note.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .padding(40)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 40)
    }
}

// MARK: - Note Card View (Grid)

struct NoteCardView: View {
    @Environment(AppState.self) private var appState
    let note: NoteRecord
    let isSelected: Bool
    var showsActions: Bool = true
    @State private var hovering = false

    private static let colorMap: [String: Color] = [
        "amber": Color(red: 0.95, green: 0.75, blue: 0.25),
        "emerald": Color(red: 0.25, green: 0.78, blue: 0.55),
        "cyan": Color(red: 0.30, green: 0.72, blue: 0.90),
        "purple": Color(red: 0.65, green: 0.45, blue: 0.90),
        "rose": Color(red: 0.95, green: 0.40, blue: 0.55),
        "slate": Color(red: 0.45, green: 0.55, blue: 0.68),
        "dark": Color.white.opacity(0.12)
    ]

    private var cardColor: Color {
        Self.colorMap[note.colorHex] ?? XTheme.accent
    }

    private var detectedURLs: [URL] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: note.content, options: [], range: NSRange(location: 0, length: note.content.utf16.count)) ?? []
        return matches.compactMap { $0.url }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header Row: Title on Left, Pin & Edit Action Buttons on Right
            HStack(alignment: .center, spacing: 6) {
                Text(note.title.isEmpty ? "Untitled Note" : note.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 4)

                if showsActions {
                    // Pin Button
                    Button {
                        appState.togglePinNote(note)
                    } label: {
                        Image(systemName: note.isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(note.isPinned ? cardColor : .white.opacity(0.6))
                            .frame(width: 26, height: 26)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                    .help(note.isPinned ? "Unpin note" : "Pin note")

                    // Edit Button
                    Button {
                        appState.editingNote = note
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 26, height: 26)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                    .help("Edit note")
                }
            }

            // Body text — starts directly below title row, 100% left aligned
            if !note.content.isEmpty {
                Text(note.content)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            // Clickable URL Badges
            if !detectedURLs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(detectedURLs.prefix(2), id: \.absoluteString) { url in
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "link")
                                    .font(.system(size: 9))
                                    .foregroundStyle(cardColor)
                                Text(url.host ?? url.absoluteString)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .glassEffect(.regular.interactive(), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Capsule())
                    }
                }
            }

            // Card Footer Row
            HStack {
                Text(note.modifiedAt.formatted(date: .numeric, time: .shortened))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
            }
        }
        .padding(12)
        .frame(minHeight: 130, alignment: .topLeading)
        .contentShape(Rectangle())
        .scaleEffect(hovering ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? cardColor.opacity(0.25) : (hovering ? cardColor.opacity(0.16) : cardColor.opacity(0.10)))
        )
        .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? XTheme.accent : (hovering ? cardColor.opacity(0.6) : cardColor.opacity(0.35)), lineWidth: isSelected ? 2 : 1)
        )
    }
}

// MARK: - Note List Row (List)

struct NoteListRow: View {
    @Environment(AppState.self) private var appState
    let note: NoteRecord
    let isSelected: Bool
    var showsActions: Bool = true
    @State private var hovering = false

    private static let colorMap: [String: Color] = [
        "amber": Color(red: 0.95, green: 0.75, blue: 0.25),
        "emerald": Color(red: 0.25, green: 0.78, blue: 0.55),
        "cyan": Color(red: 0.30, green: 0.72, blue: 0.90),
        "purple": Color(red: 0.65, green: 0.45, blue: 0.90),
        "rose": Color(red: 0.95, green: 0.40, blue: 0.55),
        "slate": Color(red: 0.45, green: 0.55, blue: 0.68),
        "dark": Color.white.opacity(0.12)
    ]

    private var cardColor: Color {
        Self.colorMap[note.colorHex] ?? XTheme.accent
    }

    var body: some View {
        HStack(spacing: 12) {
            // Note Icon badge
            ZStack {
                Circle()
                    .fill(cardColor.opacity(0.2))
                    .frame(width: 32, height: 32)
                Image(systemName: "note.text")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(cardColor)
            }

            // Title & Preview
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(note.title.isEmpty ? "Untitled Note" : note.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if note.isPinned && showsActions {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(cardColor)
                    }
                }

                Text(note.content.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer()

            // Modified Date
            Text(note.modifiedAt.formatted(date: .numeric, time: .shortened))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))

            // Action Buttons
            if showsActions {
                HStack(spacing: 6) {
                    Button {
                        appState.togglePinNote(note)
                    } label: {
                        Image(systemName: note.isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(note.isPinned ? cardColor : .white.opacity(0.6))
                            .frame(width: 28, height: 28)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())

                    Button {
                        appState.editingNote = note
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 28, height: 28)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? cardColor.opacity(0.25) : (hovering ? Color.white.opacity(0.08) : Color.white.opacity(0.04)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? XTheme.accent : (hovering ? Color.white.opacity(0.2) : Color.white.opacity(0.08)), lineWidth: isSelected ? 1.5 : 1)
        )
    }
}

// MARK: - Reliable Key Handling for the Notes Page

/// Local NSEvent monitor that makes Delete / arrows / Cmd+A / Cmd+N / Space /
/// Return work on the notes page regardless of SwiftUI focus state (same
/// mechanism TheaterView and MiniPlayerView use). Keys are only swallowed when
/// the event targets this window, nothing else is editing text, and no
/// sheet / theater / fullscreen mini-player is open.
struct NotesKeyMonitorView: NSViewRepresentable {
    let shouldDefer: () -> Bool
    let onDelete: () -> Void
    let onEscape: () -> Void
    let onArrow: (Int, Bool) -> Void
    let onSpace: () -> Void
    let onReturn: () -> Void
    let onCmdA: () -> Void
    let onCmdN: () -> Void

    func makeNSView(context: Context) -> NotesKeyView {
        let view = NotesKeyView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NotesKeyView, context: Context) {
        apply(to: nsView)
    }

    static func dismantleNSView(_ nsView: NotesKeyView, coordinator: Void) {
        nsView.teardown()
    }

    private func apply(to view: NotesKeyView) {
        view.shouldDefer = shouldDefer
        view.onDelete = onDelete
        view.onEscape = onEscape
        view.onArrow = onArrow
        view.onSpace = onSpace
        view.onReturn = onReturn
        view.onCmdA = onCmdA
        view.onCmdN = onCmdN
    }
}

final class NotesKeyView: NSView {
    var shouldDefer: (() -> Bool)?
    var onDelete: (() -> Void)?
    var onEscape: (() -> Void)?
    var onArrow: ((Int, Bool) -> Void)?
    var onSpace: (() -> Void)?
    var onReturn: (() -> Void)?
    var onCmdA: (() -> Void)?
    var onCmdN: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window != nil else { return event }
                // Only intercept keys destined for our own window — this defers
                // to open menus, sheets (note editor), and any other window.
                guard event.window === self.window else { return event }
                // Never steal keys while the user is typing in a text field/view.
                if let responder = self.window?.firstResponder,
                   responder is NSTextView || responder is NSTextField {
                    return event
                }
                // Defer to the note editor, theater viewer, or fullscreen player.
                if self.shouldDefer?() == true { return event }

                let flags = event.modifierFlags
                let chars = event.charactersIgnoringModifiers?.lowercased()

                if chars == "a" && flags.contains(.command) {
                    DispatchQueue.main.async { self.onCmdA?() }
                    return nil
                }
                if chars == "n" && flags.contains(.command) {
                    DispatchQueue.main.async { self.onCmdN?() }
                    return nil
                }

                switch event.keyCode {
                case 51: // delete / backspace
                    DispatchQueue.main.async { self.onDelete?() }
                    return nil
                case 53: // escape
                    DispatchQueue.main.async { self.onEscape?() }
                    return nil
                case 123: // left arrow
                    DispatchQueue.main.async { self.onArrow?(-1, false) }
                    return nil
                case 124: // right arrow
                    DispatchQueue.main.async { self.onArrow?(1, false) }
                    return nil
                case 125: // down arrow
                    DispatchQueue.main.async { self.onArrow?(1, true) }
                    return nil
                case 126: // up arrow
                    DispatchQueue.main.async { self.onArrow?(-1, true) }
                    return nil
                case 49: // space
                    DispatchQueue.main.async { self.onSpace?() }
                    return nil
                case 36: // return
                    DispatchQueue.main.async { self.onReturn?() }
                    return nil
                default:
                    return event
                }
            }
        } else if window == nil && monitor != nil {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }

    func teardown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
