import SwiftUI

/// Review sheet for a staged share file: the chunks are already forwarded
/// into the recipient's own vault channel (streamable/previewable), but the
/// file is NOT in the catalog until the user picks Import. Cancel deletes the
/// forwarded copies from the vault channel — the file never shows in Cascade.
struct PendingImportView: View {
    @Environment(AppState.self) private var appState
    let object: ObjectRecord
    @State private var isResolving = false

    private var kindIcon: String {
        if object.isVideo { return "play.rectangle.fill" }
        if object.isAudio { return "music.note" }
        if object.isPhoto { return "photo.fill" }
        if object.isBook { return "book.closed.fill" }
        return "doc.fill"
    }

    private var kindName: String {
        if object.isVideo { return "Video" }
        if object.isAudio { return "Audio" }
        if object.isPhoto { return "Image" }
        if object.isBook { return "Book" }
        return "Document"
    }

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: object.size, countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Shared File")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    appState.discardPendingImport()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Discard — the copy is deleted from your cloud")
            }
            .padding(20)

            VStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.quaternary.opacity(0.5))
                    Image(systemName: kindIcon)
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                }
                .frame(width: 96, height: 96)

                Text(object.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)

                HStack(spacing: 12) {
                    Label(sizeText, systemImage: "internaldrive")
                    Label(kindName, systemImage: "tag")
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                Label(
                    "The file is already in your cloud — preview it now, and only Import if you want it in your library.",
                    systemImage: "checkmark.icloud"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 8)

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                if object.isVideo || object.isAudio || object.isPhoto {
                    Button {
                        appState.openFile(object)
                    } label: {
                        Label("Preview", systemImage: "play.circle")
                    }
                    .help("Stream and preview without importing")
                }
                Spacer()
                Button(role: .destructive) {
                    appState.discardPendingImport()
                } label: {
                    Label("Cancel", systemImage: "trash")
                }
                .help("Deletes the copy from your cloud — it never shows in Cascade")
                Button {
                    isResolving = true
                    appState.confirmPendingImport()
                } label: {
                    if isResolving {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Import to My Cloud", systemImage: "arrow.down.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isResolving)
            }
            .padding(20)
        }
        .frame(width: 460, height: 420)
        .background(.regularMaterial)
    }
}