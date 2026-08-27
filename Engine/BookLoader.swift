#if os(macOS)
import Foundation

/// Loads book payloads for the reader: extracts zip-based formats (EPUB/CBZ) and
/// parses EPUB metadata (spine, TOC) into a chapter list.
enum BookLoader {

    struct Chapter {
        let title: String
        let url: URL
    }

    struct TocItem: Identifiable {
        let title: String
        let chapterIndex: Int
        var id: Int { chapterIndex }
    }

    /// Extracts a zip archive (EPUB/CBZ) into a fresh per-book temp directory and
    /// returns that directory. Uses the system `unzip` — reliable for every zip
    /// variant (zip64, data descriptors) and always present on macOS. The app is
    /// non-sandboxed, so spawning it is fine.
    static func extractArchive(fileURL: URL, fileID: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cascade-books", isDirectory: true)
            .appendingPathComponent(fileID, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-q", "-o", fileURL.path(percentEncoded: false), "-d", dir.path(percentEncoded: false)]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw BookError.extractionFailed
        }
        return dir
    }

    /// Parses an extracted EPUB directory into ordered chapters + TOC.
    /// - Returns: chapters in spine order; toc maps readable titles onto chapter
    ///   indexes (from the NCX when present, otherwise chapter-number fallbacks).
    static func loadEpub(extractedDir: URL) throws -> (chapters: [Chapter], toc: [TocItem]) {
        // 1) container.xml -> rootfile (the OPF)
        let containerURL = extractedDir.appendingPathComponent("META-INF/container.xml")
        guard let container = try? XMLDocument(contentsOf: containerURL, options: []) else {
            throw BookError.invalidEpub
        }
        let rootfiles = try container.nodes(forXPath: "//*[local-name()='rootfile']")
        guard let first = rootfiles.first as? XMLElement,
              let opfPath = first.attribute(forName: "full-path")?.stringValue else {
            throw BookError.invalidEpub
        }
        let opfURL = extractedDir.appendingPathComponent(opfPath)
        guard let opf = try? XMLDocument(contentsOf: opfURL, options: []) else {
            throw BookError.invalidEpub
        }
        let opfDir = opfURL.deletingLastPathComponent()

        // 2) manifest: id -> href
        var manifest: [String: String] = [:]
        let items = (try? opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']")) as? [XMLElement] ?? []
        for item in items {
            if let id = item.attribute(forName: "id")?.stringValue,
               let href = item.attribute(forName: "href")?.stringValue {
                manifest[id] = href
            }
        }

        // 3) spine: ordered idrefs (the reading order)
        var spine: [String] = []
        var ncxID: String? = nil
        let spineNodes = (try? opf.nodes(forXPath: "//*[local-name()='spine']")) as? [XMLElement] ?? []
        for spineEl in spineNodes {
            ncxID = spineEl.attribute(forName: "toc")?.stringValue
            let refs = (try? spineEl.nodes(forXPath: "./*[local-name()='itemref']")) as? [XMLElement] ?? []
            for ref in refs {
                if let idref = ref.attribute(forName: "idref")?.stringValue {
                    spine.append(idref)
                }
            }
        }

        // 4) chapters in spine order
        var chapters: [Chapter] = []
        var hrefToIndex: [String: Int] = [:]
        for (index, idref) in spine.enumerated() {
            guard let href = manifest[idref] else { continue }
            let url = opfDir.appendingPathComponent(href).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            hrefToIndex[url.path] = index
            chapters.append(Chapter(title: "Chapter \(index + 1)", url: url))
        }
        guard !chapters.isEmpty else { throw BookError.invalidEpub }

        // 5) TOC from the NCX (navigation control) when the book has one
        var toc: [TocItem] = []
        if let ncxID, let ncxHref = manifest[ncxID] {
            let ncxURL = opfDir.appendingPathComponent(ncxHref).standardizedFileURL
            if let ncx = try? XMLDocument(contentsOf: ncxURL, options: []) {
                let navPoints = (try? ncx.nodes(forXPath: "//*[local-name()='navPoint']")) as? [XMLElement] ?? []
                for np in navPoints {
                    let label = (try? np.nodes(forXPath: ".//*[local-name()='text']").first?.stringValue)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard let contentEl = (try? np.nodes(forXPath: ".//*[local-name()='content']").first) as? XMLElement,
                          let src = contentEl.attribute(forName: "src")?.stringValue else { continue }
                    // src may carry a #fragment — resolve the file part only
                    let pathPart = src.split(separator: "#").first.map(String.init) ?? src
                    let resolved = opfDir.appendingPathComponent(pathPart).standardizedFileURL
                    if let index = hrefToIndex[resolved.path], !label.isEmpty {
                        toc.append(TocItem(title: label, chapterIndex: index))
                    }
                }
            }
        }
        // Fall back to a plain chapter list when there's no usable NCX.
        if toc.isEmpty {
            toc = chapters.enumerated().map { TocItem(title: "Chapter \($0.offset + 1)", chapterIndex: $0.offset) }
        }
        return (chapters, toc)
    }

    /// Builds a standalone HTML document from a plain-text (or lightly-markdown)
    /// file so it renders with the reader's typography. Markdown stays as readable
    /// paragraphs for v1 (no inline markup parsing).
    static func htmlDocument(fromText text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let paragraphs = escaped
            .components(separatedBy: "\n\n")
            .map { $0.replacingOccurrences(of: "\n", with: "<br>") }
            .map { "<p>\($0)</p>" }
            .joined()
        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>\(paragraphs)</body></html>"
    }

    /// Flattens every spine chapter into ONE continuous HTML document so the whole
    /// book scrolls as a single flow (no per-chapter pages, no arrow-tapping).
    ///
    /// - Each chapter's `<body>` content is wrapped in `<section id="xc-ch-N">`
    ///   so the TOC and prev/next can jump by scrolling to the anchor.
    /// - Relative `src`/`href` URLs are rewritten to absolute `file://` URLs
    ///   against each chapter's own directory, so images and shared stylesheets
    ///   keep resolving from the flattened document at the book root.
    /// - The first chapter's `<head>` (stylesheet links etc.) is hoisted, plus
    ///   every chapter's inline `<style>` blocks (URLs resolved per chapter,
    ///   duplicates dropped).
    ///
    /// Returns the combined document's URL (saved inside the extracted dir).
    static func flattenEpub(extractedDir: URL, chapters: [Chapter]) throws -> URL {
        var sections: [String] = []
        var headContent = ""
        var extraStyles: [String] = []
        var seenStyles = Set<String>()

        for (index, chapter) in chapters.enumerated() {
            let raw = try String(contentsOf: chapter.url, encoding: .utf8)
            let base = chapter.url.deletingLastPathComponent()

            // <head> of the first chapter carries the shared stylesheets.
            if index == 0, let headStartMatch = raw.range(of: "<head[^>]*>", options: .regularExpression) {
                let headStart = headStartMatch.upperBound
                let headEnd = raw.range(of: "</head>", options: .regularExpression, range: headStart..<raw.endIndex)?.lowerBound ?? raw.endIndex
                headContent = absoluteizeURLs(in: String(raw[headStart..<headEnd]), base: base)
            }

            // Inline <style> blocks from every chapter (URLs resolved per chapter).
            let styleRegex = try NSRegularExpression(pattern: "<style[^>]*>.*?</style>", options: [.dotMatchesLineSeparators])
            let ns = raw as NSString
            for m in styleRegex.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
                let block = absoluteizeURLs(in: ns.substring(with: m.range), base: base)
                if !seenStyles.contains(block) {
                    seenStyles.insert(block)
                    extraStyles.append(block)
                }
            }

            // <body> content only (fall back to everything before </html>).
            var body: String
            if let bodyStart = raw.range(of: "<body[^>]*>", options: .regularExpression) {
                let contentStart = bodyStart.upperBound
                let contentEnd = raw.range(of: "</body>", options: .regularExpression, range: contentStart..<raw.endIndex)?.lowerBound ?? raw.endIndex
                body = String(raw[contentStart..<contentEnd])
            } else {
                let contentEnd = raw.range(of: "</html>", options: .regularExpression)?.lowerBound ?? raw.endIndex
                body = String(raw[raw.startIndex..<contentEnd])
            }

            body = absoluteizeURLs(in: body, base: base)
            sections.append("<section id=\"xc-ch-\(index)\">\(body)</section>")
        }

        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8">\(headContent)\n\(extraStyles.joined(separator: "\n"))</head><body>\(sections.joined(separator: "\n"))</body></html>
        """
        let out = extractedDir.appendingPathComponent("cascade-combined.html")
        try html.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// Rewrites relative `src`/`href`/`poster` attribute values inside HTML to
    /// absolute file URLs against `base`. In-document anchors (`#frag`), data
    /// URIs and absolute URLs are left untouched.
    static func absoluteizeURLs(in html: String, base: URL) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(src|href|poster)\s*=\s*("[^"]*"|'[^']*')"#) else { return html }
        let ns = html as NSString
        var replacements: [(NSRange, String)] = []
        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let valueRange = m.range(at: 2)
            var value = ns.substring(with: valueRange)
            let quote = value.first ?? "\""
            value.removeFirst()
            value.removeLast()
            guard let resolved = resolveRelativeURL(value, base: base) else { continue }
            replacements.append((valueRange, "\(quote)\(resolved)\(quote)"))
        }
        var result = html
        for (range, replacement) in replacements.reversed() {
            result = (result as NSString).replacingCharacters(in: range, with: replacement)
        }
        return result
    }

    private static func resolveRelativeURL(_ value: String, base: URL) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") || trimmed.hasPrefix("data:") || trimmed.hasPrefix("//") ||
           trimmed.contains("://") || trimmed.hasPrefix("mailto:") || trimmed.hasPrefix("tel:") || trimmed.isEmpty {
            return nil
        }
        // Split a trailing fragment off a relative URL (e.g. "ch2.xhtml#next")
        // so it isn't swallowed into the file name.
        let parts = trimmed.split(separator: "#", maxSplits: 1)
        let filePart = String(parts[0])
        let fragment = parts.count > 1 ? "#\(parts[1])" : ""
        guard !filePart.isEmpty else { return nil }
        return base.appendingPathComponent(filePart).standardizedFileURL.absoluteString + fragment
    }

    enum BookError: LocalizedError {
        case extractionFailed
        case invalidEpub

        var errorDescription: String? {
            switch self {
            case .extractionFailed: return "Couldn't unpack the archive. The file may be corrupted."
            case .invalidEpub: return "This EPUB couldn't be parsed — its structure is missing or unusual."
            }
        }
    }
}
#endif
