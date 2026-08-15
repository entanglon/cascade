import SwiftUI

struct NoteEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let note: NoteRecord

    private enum NoteField { case title, content }

    @FocusState private var focusedField: NoteField?
    @State private var title: String
    @State private var content: String
    @State private var colorHex: String
    @State private var isPinned: Bool
    @State private var tags: String
    @State private var isPreviewMode: Bool = false

    private static let noteColors: [(id: String, name: String, color: Color)] = [
        ("amber", "Amber", Color(red: 0.95, green: 0.75, blue: 0.25)),
        ("emerald", "Emerald", Color(red: 0.25, green: 0.78, blue: 0.55)),
        ("cyan", "Cyan", Color(red: 0.30, green: 0.72, blue: 0.90)),
        ("purple", "Purple", Color(red: 0.65, green: 0.45, blue: 0.90)),
        ("rose", "Rose", Color(red: 0.95, green: 0.40, blue: 0.55)),
        ("slate", "Slate", Color(red: 0.45, green: 0.55, blue: 0.68)),
        ("dark", "Dark Glass", Color.white.opacity(0.12))
    ]

    init(note: NoteRecord) {
        self.note = note
        _title = State(initialValue: note.title)
        _content = State(initialValue: note.content)
        _colorHex = State(initialValue: note.colorHex)
        _isPinned = State(initialValue: note.isPinned)
        _tags = State(initialValue: note.tags)
    }

    private var detectedURLs: [URL] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: content, options: [], range: NSRange(location: 0, length: content.utf16.count)) ?? []
        return matches.compactMap { $0.url }
    }

    private var cardAccentColor: Color {
        Self.noteColors.first(where: { $0.id == colorHex })?.color ?? XTheme.accent
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: 12) {
                Button {
                    isPinned.toggle()
                } label: {
                    ZStack {
                        Circle().fill(Color.black.opacity(0.35))
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isPinned ? cardAccentColor : .white.opacity(0.6))
                    }
                    .frame(width: 32, height: 32)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Unpin note" : "Pin note to top")

                Spacer()

                // Markdown preview toggle
                Button {
                    isPreviewMode.toggle()
                } label: {
                    Label(isPreviewMode ? "Edit" : "Preview", systemImage: isPreviewMode ? "pencil" : "eye")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
                .help(isPreviewMode ? "Back to editing" : "Preview rendered markdown")

                // Save / Close button
                Button("Done") {
                    saveAndClose()
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(XTheme.brandGradient, in: .capsule)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider().overlay(.white.opacity(0.1))

            // Body content area
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Title field
                    TextField("Title", text: $title)
                        .font(.system(size: 20, weight: .bold))
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .focused($focusedField, equals: .title)

                    // Detected URLs / Links bar
                    if !detectedURLs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("SAVED LINKS")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(cardAccentColor)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(detectedURLs, id: \.absoluteString) { url in
                                        Button {
                                            NSWorkspace.shared.open(url)
                                        } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: "link")
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(cardAccentColor)
                                                Text(url.host ?? url.absoluteString)
                                                    .font(.system(size: 11, weight: .medium))
                                                    .foregroundStyle(.white)
                                                    .lineLimit(1)
                                                Image(systemName: "arrow.up.right")
                                                    .font(.system(size: 9))
                                                    .foregroundStyle(.white.opacity(0.5))
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .glassEffect(.regular.interactive(), in: .capsule)
                                            .overlay(Capsule().strokeBorder(cardAccentColor.opacity(0.3), lineWidth: 1))
                                        }
                                        .buttonStyle(.plain)
                                        .contentShape(Capsule())
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    // Main Editor or Markdown Preview
                    if isPreviewMode {
                        Text(LocalizedStringKey(content.isEmpty ? "*No content*" : content))
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.9))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(0.05))
                                    .allowsHitTesting(false)
                            )
                    } else {
                        TextEditor(text: $content)
                            .font(.system(size: 14))
                            .scrollContentBackground(.hidden)
                            .foregroundStyle(.white)
                            .focused($focusedField, equals: .content)
                            .frame(minHeight: 220)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(0.05))
                                    .allowsHitTesting(false)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                                    .allowsHitTesting(false)
                            )
                    }

                    // Tags field
                    HStack(spacing: 8) {
                        Image(systemName: "tag")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                        TextField("Tags (comma separated)...", text: $tags)
                            .font(.system(size: 12))
                            .textFieldStyle(.plain)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 10))
                }
                .padding(20)
            }

            Divider().overlay(.white.opacity(0.1))

            // Footer bar: Color Picker & Delete
            HStack {
                HStack(spacing: 8) {
                    ForEach(Self.noteColors, id: \.id) { colorItem in
                        Circle()
                            .fill(colorItem.color)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.white, lineWidth: colorHex == colorItem.id ? 2 : 0)
                            )
                            .shadow(color: colorItem.color.opacity(colorHex == colorItem.id ? 0.6 : 0), radius: 6)
                            .onTapGesture {
                                colorHex = colorItem.id
                            }
                            .help(colorItem.name)
                    }
                }

                Spacer()

                Button {
                    appState.deleteNoteForever(note)
                    dismiss()
                } label: {
                    ZStack {
                        Circle().fill(Color.black.opacity(0.35))
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.red.opacity(0.85))
                    }
                    .frame(width: 32, height: 32)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Delete Note")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(cardAccentColor.opacity(0.12))
        }
        .frame(width: 540, height: 560)
        .background(AppBackground())
        .onKeyPress(.escape) {
            saveAndClose()
            return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            if press.modifiers.contains(.command) {
                saveAndClose()
                return .handled
            }
            return .ignored
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusedField = title.isEmpty ? .title : .content
            }
        }
    }

    private func saveAndClose() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty && trimmedContent.isEmpty {
            appState.deleteNoteForever(note)
            dismiss()
            return
        }
        var updated = note
        updated.title = trimmedTitle
        updated.content = content
        updated.colorHex = colorHex
        updated.isPinned = isPinned
        updated.tags = tags.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.updateNote(updated)
        dismiss()
    }
}
