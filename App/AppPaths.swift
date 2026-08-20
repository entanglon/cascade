import Foundation

/// Build-scoped data folder name. The production build (bundle id
/// `com.cascade.app.prod`) must never share state with the dev/testing
/// build (`com.cascade.app`), so each uses its own folder under
/// Application Support / Caches: separate database, TDLib state, downloads and
/// handoff files. The two builds can be installed and run side by side.
enum AppPaths {
    /// "Cascade" for the dev/testing build, "Cascade-Prod" for the production build.
    static var dataFolder: String {
        if Bundle.main.bundleIdentifier?.hasSuffix(".prod") == true {
            return "Cascade-Prod"
        }
        return "Cascade"
    }
}

// MARK: - File-Backed Structured Log Manager

actor LogManager {
    static let shared = LogManager()

    enum Level: String, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    private let maxFileSize: Int64 = 5 * 1024 * 1024 // 5 MB
    private let maxRotations = 3

    func logDirectory() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let logsDir = support.appendingPathComponent(AppPaths.dataFolder, isDirectory: true).appendingPathComponent("logs", isDirectory: true)
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        return logsDir
    }

    func currentLogURL() -> URL {
        logDirectory().appendingPathComponent("cascade.log")
    }

    func log(_ message: String, level: Level = .info, subsystem: String = "app") {
        let logURL = currentLogURL()
        rotateIfNeeded(logURL: logURL)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        let line = "\(timestamp) [\(level.rawValue)] [\(subsystem)] \(message)\n"

        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    private func rotateIfNeeded(logURL: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? Int64,
              size >= maxFileSize else { return }

        let dir = logDirectory()
        for i in stride(from: maxRotations - 1, through: 1, by: -1) {
            let src = dir.appendingPathComponent("cascade.\(i).log")
            let dst = dir.appendingPathComponent("cascade.\(i + 1).log")
            if fm.fileExists(atPath: src.path) {
                try? fm.removeItem(at: dst)
                try? fm.moveItem(at: src, to: dst)
            }
        }
        let firstBackup = dir.appendingPathComponent("cascade.1.log")
        try? fm.removeItem(at: firstBackup)
        try? fm.moveItem(at: logURL, to: firstBackup)
    }

    func readRecentLogs(limit: Int = 100) -> [String] {
        let logURL = currentLogURL()
        guard let content = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        return Array(lines.suffix(limit))
    }
}