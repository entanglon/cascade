import SwiftUI
import WebKit

/// A dedicated, distraction-free reader for books in the vault. Renders:
/// - **EPUB**: chapterized web rendering with TOC, themes and font sizing
/// - **TXT / MD**: the same typographic web rendering
/// - **PDF**: native WebKit PDF rendering in the same chrome
/// - **CBZ / CBR**: comics — paged or vertical webtoon scroll
struct BookReaderView: View {
    @Environment(AppState.self) private var appState
    let file: ObjectRecord
    /// When set (reader full screen), close/Esc call this instead of closing the
    /// windowed reader.
    var onClose: (() -> Void)? = nil

    private enum Format { case epub, pdf, text, comic, unsupported }

    @State private var format: Format = .unsupported
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var downloadProgress: Double = 0

    // EPUB / text
    @State private var chapters: [BookLoader.Chapter] = []
    @State private var toc: [BookLoader.TocItem] = []
    @State private var chapterIndex = 0
    @State private var chapterDocURL: URL?
    @State private var readAccessDir: URL?
    @State private var showTOC = false
    /// Chapter anchor to scroll to inside the combined document (the book is one
    /// continuous scrollable page — TOC/arrows scroll, they don't reload pages).
    @State private var scrollTarget: Int? = nil
    /// Live scroll position (0...1) reported by the web view — the progress bar
    /// tracks real reading position, not just chapter switches.
    @State private var scrollFraction: Double = 0
    // Chrome auto-hides while reading (Apple Books style): the toolbars fade out
    // when the cursor is idle in the page, and reappear near the top/bottom edge.
    @State private var chromeVisible = true
    @State private var hideChromeTask: Task<Void, Never>?

    // Comic
    @State private var pages: [URL] = []
    @State private var pageIndex = 0

    // PDF
    @State private var pdfURL: URL?

    @AppStorage("xc.reader.fontSize") private var fontSize = 18.0
    @AppStorage("xc.reader.theme") private var themeRaw = "sepia"
    @AppStorage("xc.reader.comicMode") private var comicModeRaw = "paged"

    private var progressKey: String { "xc.reader.progress.\(file.id)" }
    /// Fractional position (0...1) — the Library shelf reads this to draw the
    /// Apple Books-style progress bar on the cover.
    private var progressFractionKey: String { "xc.reader.progressFraction.\(file.id)" }

    private var theme: ReaderTheme {
        ReaderTheme(rawValue: themeRaw) ?? .sepia
    }

    private var isWebBook: Bool { format == .epub || format == .text }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                theme.background.ignoresSafeArea()

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Floating top/bottom controls — auto-hide while reading
                VStack {
                    topControls
                    Spacer()
                    bottomControls
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .opacity(chromeVisible ? 1 : 0)
                .allowsHitTesting(chromeVisible)
                .animation(.easeOut(duration: 0.25), value: chromeVisible)
            }
            .onContinuousHover { phase in
                handleHover(phase, height: geo.size.height)
            }
        }
        .onAppear {
            load()
            // Give the bars a moment on open, then fade them out.
            scheduleChromeHide(delay: 3)
        }
        .onChange(of: chapterIndex) { _, newIndex in
            UserDefaults.standard.set(newIndex, forKey: progressKey)
            if format == .comic && pages.count > 1 {
                UserDefaults.standard.set(
                    min(max(Double(newIndex) / Double(pages.count - 1), 0), 1),
                    forKey: progressFractionKey
                )
            }
        }
        .overlay {
            if isLoading {
                loadingOverlay
            }
        }
        .overlay {
            if let errorMessage {
                errorOverlay(errorMessage)
            }
        }
        .sheet(isPresented: $showTOC) { tocPanel }
        .animation(.easeInOut(duration: 0.15), value: chapterIndex)
        .animation(.easeInOut(duration: 0.15), value: pageIndex)
        .background(
            // Arrow keys flip chapters/pages; Esc closes. Space is left to the web
            // view (scrolling) except in comics, where it advances the page.
            KeyMonitorView(
                onEscape: { onClose?() ?? (appState.readerFile = nil) },
                onLeftArrow: { navigate(delta: -1) },
                onRightArrow: { navigate(delta: 1) },
                onUpArrow: nil,
                onDownArrow: nil,
                onSpacebar: format == .comic ? { navigate(delta: 1) } : nil
            )
            .frame(width: 0, height: 0)
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch format {
        case .epub, .text:
            if let chapterDocURL, let readAccessDir {
                BookWebView(
                    url: chapterDocURL,
                    readAccessURL: readAccessDir,
                    css: readerCSS,
                    scrollTarget: scrollTarget,
                    onScroll: { fraction, chapter in
                        scrollFraction = fraction
                        if chapterIndex != chapter { chapterIndex = chapter }
                        persistScrollFraction(fraction)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .pdf:
            if let pdfURL {
                BookWebView(url: pdfURL, readAccessURL: pdfURL.deletingLastPathComponent(), css: "")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .comic:
            comicContent
        case .unsupported:
            VStack(spacing: 16) {
                Image(systemName: "book.closed")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(theme.foreground.opacity(0.5))
                Text("This book format isn't supported in the reader yet")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.foreground)
                Button("Open with Default App") { openExternally() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(XTheme.accent))
            }
        }
    }

    @ViewBuilder
    private var comicContent: some View {
        if comicModeRaw == "webtoon" {
            ScrollView([.vertical, .horizontal]) {
                VStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.element) { _, url in
                        if let img = NSImage(contentsOf: url) {
                            Image(nsImage: img)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        } else if pages.indices.contains(pageIndex) {
            ZStack {
                if let img = NSImage(contentsOf: pages[pageIndex]) {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Top bar

    /// Floating liquid-glass toolbar (the app's signature chrome, same as the
    /// theater's): a capsule of regular glass material over the page, with
    /// interactive glass buttons. The page shows through around it and the
    /// toolbar never blocks content — the reader CSS reserves enough top padding
    /// so the first line stays clear.
    private var topControls: some View {
        HStack(spacing: 8) {
            Button {
                onClose?() ?? (appState.readerFile = nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.foreground)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")

            VStack(alignment: .leading, spacing: 1) {
                Text(bookTitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isWebBook, !toc.isEmpty {
                    Text(currentChapterTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.foreground.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .padding(.leading, 4)

            Spacer()

            if isWebBook {
                fontButtons
                themeButton
            }
            if format == .epub, !toc.isEmpty {
                tocButton
            }
            fullscreenButton
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    private var fullscreenButton: some View {
        Button {
            ReaderFullScreenWindow.shared.present(file: file, appState: appState)
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.foreground)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .help("Full Screen (Esc to exit)")
    }

    private var fontButtons: some View {
        HStack(spacing: 2) {
            Button {
                fontSize = min(28, max(12, fontSize - 1))
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Smaller text")

            Button {
                fontSize = min(28, max(12, fontSize + 1))
            } label: {
                Image(systemName: "textformat.size.larger")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Larger text")
        }
        .padding(2)
        .glassEffect(.regular, in: .capsule)
    }

    private var themeButton: some View {
        Button {
            themeRaw = theme.next.rawValue
        } label: {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.foreground)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .help("Theme: \(theme.title) (next: \(theme.next.title))")
    }

    private var tocButton: some View {
        Button {
            showTOC = true
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.foreground)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .help("Table of Contents")
    }

    // MARK: - Bottom bar

    /// Floating liquid-glass page-nav bar: prev/next chevrons, a progress capsule
    /// and the position readout, all in one glass capsule centered at the bottom
    /// of the page. The reader CSS reserves enough bottom padding so the last
    /// line never hides under it.
    private var bottomControls: some View {
        HStack(spacing: 14) {
            Button {
                navigate(delta: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.foreground)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .help("Previous (←)")

            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.foreground.opacity(0.15))
                        Capsule()
                            .fill(XTheme.accent)
                            .frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 4)

                Text(progressText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.foreground.opacity(0.65))
            }
            .frame(width: 180)

            Button {
                navigate(delta: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.foreground)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .help("Next (→)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }

    // MARK: - TOC

    private var tocPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Contents")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    showTOC = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider().overlay(Color.white.opacity(0.1))

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(toc) { item in
                        Button {
                            chapterIndex = item.chapterIndex
                            scrollTarget = item.chapterIndex
                            showTOC = false
                        } label: {
                            HStack(spacing: 10) {
                                Text(item.title)
                                    .font(.system(size: 13, weight: chapterIndex == item.chapterIndex ? .semibold : .regular))
                                    .foregroundStyle(chapterIndex == item.chapterIndex ? XTheme.accent : .white.opacity(0.8))
                                    .multilineTextAlignment(.leading)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(chapterIndex == item.chapterIndex ? XTheme.accent.opacity(0.15) : .clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .frame(width: 340, height: 460)
        .background(AppBackground())
    }

    // MARK: - Loading / error

    private var loadingOverlay: some View {
        ZStack {
            theme.background.opacity(0.92)
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.foreground.opacity(0.6))
                Text(downloadProgress >= 1 ? "Opening book…" : "Downloading…")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.foreground.opacity(0.6))
                if downloadProgress > 0 && downloadProgress < 1 {
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.foreground.opacity(0.4))
                }
            }
        }
        .transition(.opacity)
    }

    private func errorOverlay(_ message: String) -> some View {
        ZStack {
            theme.background.opacity(0.96)
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(theme.foreground.opacity(0.5))
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.foreground.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                Button("Close") { appState.readerFile = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(XTheme.accent))
            }
        }
        .transition(.opacity)
    }

    // MARK: - State

    private var progress: Double {
        switch format {
        case .epub, .text:
            // Live scroll fraction — the whole book is one continuous document,
            // so reading position is where you are in the scroll flow.
            return scrollFraction
        case .comic:
            return pages.isEmpty ? 0 : Double(pageIndex + 1) / Double(pages.count)
        case .pdf, .unsupported:
            return 0
        }
    }

    private var progressText: String {
        switch format {
        case .epub, .text:
            return "\(chapterIndex + 1) / \(chapters.count) · \(Int((progress * 100).rounded()))%"
        case .comic:
            return comicModeRaw == "webtoon" ? "\(pages.count) pages" : "\(pageIndex + 1) / \(pages.count)"
        case .pdf:
            return "PDF"
        case .unsupported:
            return ""
        }
    }

    private var bookTitle: String {
        (file.name as NSString).deletingPathExtension
    }

    private var currentChapterTitle: String {
        toc.first(where: { $0.chapterIndex == chapterIndex })?.title ?? chapters[safe: chapterIndex]?.title ?? ""
    }

    private var readerCSS: String {
        let t = theme
        return """
        :root { --xc-bg: \(t.backgroundHex); --xc-fg: \(t.foregroundHex); --xc-link: \(t.accentHex); }
        html, body { background: var(--xc-bg) !important; }
        body {
            color: var(--xc-fg) !important;
            font-family: Georgia, 'Iowan Old Style', 'Times New Roman', serif !important;
            font-size: \(fontSize)px !important;
            line-height: 1.7 !important;
            max-width: 42em !important;
            margin: 0 auto !important;
            /* Clearance for the floating glass toolbars (top ~56pt, bottom ~68pt). */
            padding: 76px 32px 96px !important;
            overflow-wrap: break-word !important;
        }
        p { margin: 0 0 1.15em !important; text-align: justify !important; }
        h1, h2, h3, h4 { color: var(--xc-fg) !important; line-height: 1.3 !important; margin: 1.4em 0 0.6em !important; }
        a { color: var(--xc-link) !important; }
        img { max-width: 100% !important; height: auto !important; }
        blockquote { margin: 1em 0 !important; padding-left: 1em !important; border-left: 3px solid var(--xc-fg) !important; opacity: 0.85 !important; }
        """
    }

    private func navigate(delta: Int) {
        switch format {
        case .epub, .text:
            guard !chapters.isEmpty else { return }
            chapterIndex = min(max(0, chapterIndex + delta), chapters.count - 1)
            scrollTarget = chapterIndex
        case .comic:
            guard !pages.isEmpty else { return }
            pageIndex = min(max(0, pageIndex + delta), pages.count - 1)
        case .pdf, .unsupported:
            break
        }
    }

    // MARK: - Chrome auto-hide

    private func handleHover(_ phase: HoverPhase, height: CGFloat) {
        switch phase {
        case .active(let location):
            hideChromeTask?.cancel()
            let nearEdge = location.y < 76 || location.y > height - 76
            if nearEdge {
                withAnimation(.easeOut(duration: 0.2)) { chromeVisible = true }
            } else {
                scheduleChromeHide(delay: 1.6)
            }
        case .ended:
            scheduleChromeHide(delay: 1.2)
        @unknown default:
            break
        }
    }

    private func scheduleChromeHide(delay: Double) {
        hideChromeTask?.cancel()
        hideChromeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { chromeVisible = false }
        }
    }

    // MARK: - Loading

    private func load() {
        isLoading = true
        errorMessage = nil
        let ext = (file.name as NSString).pathExtension.lowercased()
        format = Self.format(forExtension: ext)

        Task {
            do {
                let url = try await DownloadEngine.download(object: file, quiet: true) { _, progress in
                    Task { @MainActor in self.downloadProgress = progress }
                }
                await MainActor.run { finishLoad(cacheURL: url) }
            } catch {
                await MainActor.run {
                    errorMessage = "Couldn't download the book: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }

    /// Throttled fraction write (0...1) so scroll events don't hammer
    /// UserDefaults — only meaningful deltas (>= 0.5%) are persisted.
    private func persistScrollFraction(_ fraction: Double) {
        guard fraction > 0 else { return }
        let clamped = min(max(fraction, 0), 1)
        guard abs(clamped - UserDefaults.standard.double(forKey: progressFractionKey)) > 0.005 else { return }
        UserDefaults.standard.set(clamped, forKey: progressFractionKey)
    }

    @MainActor
    private func finishLoad(cacheURL: URL) {
        switch format {
        case .epub:
            do {
                let dir = try BookLoader.extractArchive(fileURL: cacheURL, fileID: file.id)
                let (chs, tocList) = try BookLoader.loadEpub(extractedDir: dir)
                chapters = chs
                toc = tocList
                readAccessDir = dir
                // One continuous scrollable document — every book reads the same
                // way (scroll), regardless of how the publisher split its spine.
                chapterDocURL = try BookLoader.flattenEpub(extractedDir: dir, chapters: chs)
                let saved = UserDefaults.standard.integer(forKey: progressKey)
                chapterIndex = chs.isEmpty ? 0 : min(max(0, saved), chs.count - 1)
                scrollTarget = chapterIndex
            } catch {
                errorMessage = error.localizedDescription
            }
        case .text:
            do {
                let text = try String(contentsOf: cacheURL, encoding: .utf8)
                let html = BookLoader.htmlDocument(fromText: text)
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("xcloud-books", isDirectory: true)
                    .appendingPathComponent(file.id, isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let docURL = dir.appendingPathComponent("reader.html")
                try html.write(to: docURL, atomically: true, encoding: .utf8)
                chapters = [BookLoader.Chapter(title: file.name, url: docURL)]
                toc = [BookLoader.TocItem(title: bookTitle, chapterIndex: 0)]
                readAccessDir = dir
                chapterIndex = 0
                chapterDocURL = docURL
            } catch {
                errorMessage = "Couldn't read the text file: \(error.localizedDescription)"
            }
        case .pdf:
            pdfURL = cacheURL
        case .comic:
            do {
                let dir = try BookLoader.extractArchive(fileURL: cacheURL, fileID: file.id)
                pages = Self.imageFiles(in: dir)
                if pages.isEmpty { errorMessage = "No images found in the comic archive." }
            } catch {
                errorMessage = error.localizedDescription
            }
        case .unsupported:
            break
        }
        isLoading = false
    }

    private func openExternally() {
        Task {
            let url = try? await DownloadEngine.download(object: file, quiet: true) { _, _ in }
            if let url { NSWorkspace.shared.open(url) }
        }
    }

    private static func format(forExtension ext: String) -> Format {
        switch ext {
        case "epub": return .epub
        case "pdf": return .pdf
        case "txt", "md", "markdown": return .text
        case "cbz", "cbr": return .comic
        default: return .unsupported
        }
    }

    /// All image files inside a directory tree, natural-sorted (page 2 < page 10).
    private static func imageFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        let imgs = (try? fm.subpathsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? []
        return imgs
            .filter { ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff"].contains(($0 as NSString).pathExtension.lowercased()) }
            .map { dir.appendingPathComponent($0) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

// MARK: - Reader theme

private enum ReaderTheme: String, CaseIterable {
    case light, sepia, dark

    var title: String {
        switch self {
        case .light: return "Light"
        case .sepia: return "Sepia"
        case .dark: return "Dark"
        }
    }

    var background: Color {
        switch self {
        case .light: return Color(red: 0.98, green: 0.97, blue: 0.95)
        case .sepia: return Color(red: 0.95, green: 0.92, blue: 0.85)
        case .dark: return Color(red: 0.08, green: 0.08, blue: 0.08)
        }
    }

    var foreground: Color {
        switch self {
        case .light: return Color(red: 0.16, green: 0.16, blue: 0.15)
        case .sepia: return Color(red: 0.29, green: 0.25, blue: 0.18)
        case .dark: return Color(red: 0.84, green: 0.82, blue: 0.78)
        }
    }

    var backgroundHex: String {
        switch self {
        case .light: return "#FAF8F2"
        case .sepia: return "#F2EAD8"
        case .dark: return "#141414"
        }
    }

    var foregroundHex: String {
        switch self {
        case .light: return "#292927"
        case .sepia: return "#4A3F2E"
        case .dark: return "#D6D2C7"
        }
    }

    var accentHex: String {
        switch self {
        case .light: return "#0A5BD3"
        case .sepia: return "#8A5A2B"
        case .dark: return "#7FA7E8"
        }
    }

    var next: ReaderTheme {
        switch self {
        case .light: return .sepia
        case .sepia: return .dark
        case .dark: return .light
        }
    }
}

// MARK: - Web reader

/// WKWebView wrapper for the book: loads the (flattened, continuous) document
/// with read access to the extracted book directory so CSS/images resolve, and
/// (re)injects the reader's typography CSS on every navigation and every
/// font/theme change. A `scrollTarget` (chapter index) scrolls the page to the
/// matching `#xc-ch-N` anchor instead of reloading a per-chapter page.
///
/// The web view also reports live scroll progress: a JS listener posts the
/// scroll fraction and the current chapter (via `window.webkit.messageHandlers`)
/// on every scroll tick, so the reader's progress bar tracks real reading.
struct BookWebView: NSViewRepresentable {
    let url: URL
    let readAccessURL: URL
    let css: String
    var scrollTarget: Int? = nil
    var onScroll: ((Double, Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "xcScroll")
        config.userContentController = userContent
        let web = NonMenuWKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        context.coordinator.onScroll = onScroll
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.onScroll = onScroll
        context.coordinator.pendingCSS = css
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            web.loadFileURL(url, allowingReadAccessTo: readAccessURL)
        } else {
            context.coordinator.inject(web)
        }
        if let target = scrollTarget, target != context.coordinator.lastScrollTarget {
            context.coordinator.lastScrollTarget = target
            context.coordinator.scroll(to: target, in: web)
        }
    }

    private struct ScrollPayload: Codable {
        let f: Double
        let c: Int
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loadedURL: URL?
        var pendingCSS = ""
        var lastScrollTarget: Int? = nil
        var onScroll: ((Double, Int) -> Void)? = nil

        private static let scrollReporterJS = """
        (function(){
          if (window.__xcScrollInstalled) return;
          window.__xcScrollInstalled = true;
          function report(){
            var doc = document.documentElement || document.body;
            var max = Math.max(doc.scrollHeight, document.body.scrollHeight) - window.innerHeight;
            var y = window.scrollY;
            var idx = 0;
            var sections = document.querySelectorAll('section[id^="xc-ch-"]');
            for (var i = 0; i < sections.length; i++) {
              if (sections[i].offsetTop <= y + 1) idx = parseInt(sections[i].id.slice(6), 10) || 0;
            }
            try {
              window.webkit.messageHandlers.xcScroll.postMessage(JSON.stringify({
                f: max > 0 ? Math.min(1, Math.max(0, y / max)) : 0,
                c: idx
              }));
            } catch(e) {}
          }
          var ticking = false;
          window.addEventListener('scroll', function(){
            if (ticking) return; ticking = true;
            requestAnimationFrame(function(){ ticking = false; report(); });
          });
          window.addEventListener('resize', function(){ report(); });
          report();
        })();
        """

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "xcScroll",
                  let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(ScrollPayload.self, from: data) else { return }
            let fraction = payload.f
            let chapter = payload.c
            Task { @MainActor in
                onScroll?(fraction, chapter)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            inject(webView)
            webView.evaluateJavaScript(Self.scrollReporterJS, completionHandler: nil)
            if let target = lastScrollTarget {
                scroll(to: target, in: webView)
            }
        }

        func scroll(to chapterIndex: Int, in webView: WKWebView) {
            let js = "var el = document.getElementById('xc-ch-\(chapterIndex)'); if (el) el.scrollIntoView({block:'start'});"
            webView.evaluateJavaScript(js)
        }

        func inject(_ webView: WKWebView) {
            guard !pendingCSS.isEmpty else { return }
            // JSONEncoder is used (not JSONSerialization): it cannot crash on any
            // Swift String, whereas data(withJSONObject:) raises an uncaught ObjC
            // exception for top-level strings, which SIGABRTs the app.
            let cssLiteral = (try? JSONEncoder().encode(pendingCSS))
                .map { String(data: $0, encoding: .utf8) ?? "\"\"" } ?? "\"\""
            let js = """
            (function() {
                var s = document.getElementById('xc-reader-style');
                if (!s) { s = document.createElement('style'); s.id = 'xc-reader-style'; document.head.appendChild(s); }
                s.textContent = \(cssLiteral);
            })()
            """
            webView.evaluateJavaScript(js)
        }
    }
}

// MARK: - Reader full screen

/// Reader-only full screen: a borderless window covering the screen, mirroring the
/// video player's approach (PlayerFullScreenWindow). The app window stays put and
/// the reader re-opens in the full screen window (progress is restored from
/// UserDefaults, so the position carries over). Esc dismisses it.
final class ReaderFullScreenWindow: NSObject {
    static let shared = ReaderFullScreenWindow()

    private var window: NSWindow?
    private var keyMonitor: Any?
    private(set) var isActive = false

    private override init() {
        super.init()
    }

    func present(file: ObjectRecord, appState: AppState) {
        guard !isActive, window == nil else { return }
        isActive = true

        let screen = NSScreen.main ?? NSScreen.screens.first
        let win = NSWindow(
            contentRect: screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.level = .mainMenu
        win.backgroundColor = .black
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.fullScreenAuxiliary, .stationary]

        let reader = BookReaderView(file: file, onClose: { [weak self] in
            self?.dismiss()
        })
        .environment(appState)
        .ignoresSafeArea()

        let hosting = NSHostingView(rootView: reader)
        hosting.frame = win.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        win.contentView = hosting

        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Esc exits full screen; swallow it so the underlying reader's monitor
        // doesn't also close the windowed reader.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.dismiss()
                return nil
            }
            return event
        }
    }

    func dismiss() {
        guard isActive, let win = window else { return }
        isActive = false
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        win.orderOut(nil)
        win.close()
        window = nil
    }
}

// MARK: - Small helpers

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
