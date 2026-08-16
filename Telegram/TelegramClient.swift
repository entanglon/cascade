import Foundation
import TDLibKit
import os

enum TelegramError: Swift.Error, Sendable {
    case notInitialized
    case joinFailed(String)
}

enum TelegramAuthStep: String, Sendable {
    case phone
    case code
    case password
    case confirmation
    case ready
    case unknown
}

@Observable
final class TelegramClient {
    static let shared = TelegramClient()

    private let manager = TDLibClientManager()
    private var client: TDLibClient?

    private let logger = Logger(
        subsystem: "com.xcloud.app",
        category: "telegram"
    )

    // MARK: - State

    var isConnected = false
    var isAuthorized = false
    var authStep: TelegramAuthStep = .unknown

    /// True once TDLib has reported a real authorization state (waiting for phone,
    /// code, password, confirmation, or ready). Until then the app can't know whether
    /// the user is logged in, so the UI shows a neutral splash instead of flashing the
    /// login screen on every launch.
    var isAuthResolved = false

    /// True once setTdlibParameters has been sent (the client exists), regardless of
    /// whether authorization has completed. Lets the login gate decide whether to start
    /// TDLib from stored credentials.
    var isClientStarted: Bool { client != nil }

    private var currentAPIID: Int?
    private var currentAPIHash: String?

    // MARK: - Configuration

    func configure(apiID: Int, apiHash: String) {
        currentAPIID = apiID
        currentAPIHash = apiHash
    }

    // MARK: - Initialization

    func start() async throws {
        guard client == nil else { return }
        guard let apiID = currentAPIID,
              let apiHash = currentAPIHash else {
            throw TelegramError.notInitialized
        }

        let newClient = manager.createClient { [weak self] data, client in
            guard let self else { return }
            Task { await self.handleUpdate(data: data) }
        }

        client = newClient

        try await newClient.setTdlibParameters(
            apiHash: apiHash,
            apiId: apiID,
            applicationVersion: "1.0",
            databaseDirectory: databasePath(),
            databaseEncryptionKey: Data(),
            deviceModel: "Mac",
            filesDirectory: filesPath(),
            systemLanguageCode: "en",
            systemVersion: "macOS",
            useChatInfoDatabase: true,
            useFileDatabase: true,
            useMessageDatabase: true,
            useSecretChats: false,
            useTestDc: false
        )

        logger.info("TDLib client started")
    }

    // MARK: - Tracking
    // These are accessed from TDLib's receive thread (via update handlers) and from
    // task-cancellation handlers, so they are explicitly nonisolated and guarded by
    // the lock rather than the MainActor isolation.
    @ObservationIgnored nonisolated(unsafe) private var pendingSendContinuations: [Int64: CheckedContinuation<Int64, any Swift.Error>] = [:]
    @ObservationIgnored nonisolated(unsafe) private var completedSends: [Int64: Result<Int64, any Swift.Error>] = [:]
    @ObservationIgnored nonisolated(unsafe) private var fileDownloadProgressHandlers: [Int: (Double) -> Void] = [:]
    @ObservationIgnored nonisolated(unsafe) private var fileUploadProgressHandlers: [Int: (Double) -> Void] = [:]
    @ObservationIgnored nonisolated(unsafe) private var fileDownloadContinuations: [Int: CheckedContinuation<String, any Swift.Error>] = [:]
    @ObservationIgnored nonisolated(unsafe) private var fileDownloadWatchdogs: [Int: Task<Void, Never>] = [:]
    /// Set once a download has shown real progress (active or bytes moved). Guards
    /// against treating the initial updateFile — emitted before any download started
    /// — as a "stopped without completing" failure.
    @ObservationIgnored nonisolated(unsafe) private var fileDownloadSeenProgress: Set<Int> = []
    @ObservationIgnored nonisolated(unsafe) private var fileUploadContinuations: [Int: CheckedContinuation<Int, any Swift.Error>] = [:]
    nonisolated private let trackingLock = NSLock()
    nonisolated private func syncLock<T>(_ work: () -> T) -> T {
        trackingLock.lock()
        defer { trackingLock.unlock() }
        return work()
    }

    private func parseInt64(_ value: Any?) -> Int64? {
        if let num = value as? NSNumber { return num.int64Value }
        if let str = value as? String, let val = Int64(str) { return val }
        return nil
    }

    // MARK: - Update handling

    private func handleUpdate(data: Data) async {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["@type"] as? String else { return }

        switch type {
        case "updateAuthorizationState":
            if let state = json["authorization_state"] as? [String: Any],
               let stateType = state["@type"] as? String {
                Task { @MainActor in
                    switch stateType {
                    case "authorizationStateWaitTdlibParameters":
                        self.authStep = .unknown
                    case "authorizationStateWaitPhoneNumber":
                        self.authStep = .phone
                        self.isConnected = true
                        self.isAuthorized = false
                        self.isAuthResolved = true
                    case "authorizationStateWaitCode":
                        self.authStep = .code
                        self.isConnected = true
                        self.isAuthorized = false
                        self.isAuthResolved = true
                    case "authorizationStateWaitPassword":
                        self.authStep = .password
                        self.isConnected = true
                        self.isAuthorized = false
                        self.isAuthResolved = true
                    case "authorizationStateWaitOtherDeviceConfirmation":
                        self.authStep = .confirmation
                        self.isConnected = true
                        self.isAuthorized = false
                        self.isAuthResolved = true
                    case "authorizationStateReady":
                        self.authStep = .ready
                        self.isConnected = true
                        self.isAuthorized = true
                        self.isAuthResolved = true
                        self.logger.info("Telegram authorized successfully")
                    default:
                        self.authStep = .unknown
                    }
                }
            }

        case "updateFile":
            if let file = json["file"] as? [String: Any],
               let fileId = file["id"] as? Int {

                let totalSize = (file["expected_size"] as? NSNumber)?.doubleValue ?? (file["size"] as? NSNumber)?.doubleValue ?? 0

                // Upload tracking (remote branch ONLY)
                if let remote = file["remote"] as? [String: Any] {
                    let isUploading = (remote["is_uploading_active"] as? Bool) ?? false
                    let isCompleted = (remote["is_uploading_completed"] as? Bool) ?? false
                    let uploaded = (remote["uploaded_size"] as? NSNumber)?.doubleValue ?? (remote["uploadedSize"] as? NSNumber)?.doubleValue ?? 0

                    if (isUploading || isCompleted || uploaded > 0), let handler = syncLock({ fileUploadProgressHandlers[fileId] }) {
                        handler(isCompleted ? 1.0 : (totalSize > 0 ? min(max(0, uploaded / totalSize), 1.0) : 0))
                    }

                    if isCompleted || (totalSize > 0 && uploaded >= totalSize) {
                        let continuation = syncLock { fileUploadContinuations.removeValue(forKey: fileId) }
                        continuation?.resume(returning: fileId)
                    }
                }

                // Download tracking (local branch ONLY)
                if let local = file["local"] as? [String: Any] {
                    let isDownloading = (local["is_downloading_active"] as? Bool) ?? false
                    let isCompleted = (local["is_downloading_completed"] as? Bool) ?? false || (local["isDownloadingCompleted"] as? Bool) ?? false
                    let downloaded = (local["downloaded_size"] as? NSNumber)?.doubleValue ?? (local["downloadedSize"] as? NSNumber)?.doubleValue ?? 0
                    let path = (local["path"] as? String) ?? ""

                    if (isDownloading || isCompleted || downloaded > 0), let handler = syncLock({ fileDownloadProgressHandlers[fileId] }) {
                        handler(isCompleted ? 1.0 : (totalSize > 0 ? min(max(0, downloaded / totalSize), 1.0) : 0))
                    }

                    if isDownloading || downloaded > 0 {
                        syncLock { fileDownloadSeenProgress.insert(fileId) }
                    }

                    if isCompleted && !path.isEmpty {
                        let continuation = syncLock { fileDownloadContinuations.removeValue(forKey: fileId) }
                        syncLock { fileDownloadWatchdogs.removeValue(forKey: fileId)?.cancel() }
                        continuation?.resume(returning: path)
                    } else if !isDownloading && !isCompleted, syncLock({ fileDownloadSeenProgress.contains(fileId) }) {
                        // The download stopped without completing (network failure or
                        // TDLib gave up). Resume the waiter with an error instead of
                        // leaking its continuation and hanging "Downloading chunk"
                        // forever (SWIFT TASK CONTINUATION MISUSE).
                        let continuation = syncLock { fileDownloadContinuations.removeValue(forKey: fileId) }
                        syncLock { fileDownloadWatchdogs.removeValue(forKey: fileId)?.cancel() }
                        continuation?.resume(throwing: DownloadError.downloadFailed)
                    }
                }
            }

        case "updateMessageSendSucceeded":
            if let oldId = parseInt64(json["old_message_id"]),
               let message = json["message"] as? [String: Any],
               let realId = parseInt64(message["id"]) {
                let continuation = syncLock { self.pendingSendContinuations.removeValue(forKey: oldId) }
                if let continuation {
                    continuation.resume(returning: realId)
                } else {
                    syncLock { self.completedSends[oldId] = .success(realId) }
                }
            }

        case "updateMessageSendFailed":
            if let oldId = parseInt64(json["old_message_id"]) {
                let code = (json["error_code"] as? NSNumber)?.intValue ?? 0
                let msg = (json["error_message"] as? String) ?? "Upload failed"
                let err: any Swift.Error = NSError(domain: "Telegram", code: code, userInfo: [NSLocalizedDescriptionKey: msg])
                let continuation = syncLock { self.pendingSendContinuations.removeValue(forKey: oldId) }
                if let continuation {
                    continuation.resume(throwing: err)
                } else {
                    syncLock { self.completedSends[oldId] = .failure(err) }
                }
            }

        default:
            break
        }
    }

    // MARK: - Auth actions

    func setAuthenticationPhoneNumber(_ phone: String) async throws {
        guard let client else { throw TelegramError.notInitialized }

        let settings = PhoneNumberAuthenticationSettings(
            allowFlashCall: false,
            allowMissedCall: false,
            allowSmsRetrieverApi: false,
            authenticationTokens: [],
            firebaseAuthenticationSettings: nil,
            hasUnknownPhoneNumber: false,
            isCurrentPhoneNumber: true
        )

        try await client.setAuthenticationPhoneNumber(
            phoneNumber: phone,
            settings: settings
        )
    }

    func checkAuthenticationCode(_ code: String) async throws {
        guard let client else { throw TelegramError.notInitialized }
        try await client.checkAuthenticationCode(code: code)
    }

    func checkAuthenticationPassword(_ password: String) async throws {
        guard let client else { throw TelegramError.notInitialized }
        try await client.checkAuthenticationPassword(password: password)
    }

    func resendAuthenticationCode() async throws {
        guard let client else { throw TelegramError.notInitialized }
        try await client.resendAuthenticationCode(reason: nil)
    }

    // MARK: - Auth error display

    private static let authLogger = Logger(subsystem: "com.xcloud.app", category: "auth")

    /// TDLibKit's `Error` type does not conform to `LocalizedError`, so Swift turns every
    /// failure into a useless "The operation couldn't be completed. (TDLibKit.Error error 1.)".
    /// This extracts the real code/message and maps the common auth failures to readable text.
    static func describeAuthError(_ error: any Swift.Error, method: String = "") -> String {
        if let td = error as? TDLibKit.Error {
            let msg = td.message
            // `privacy: .public` so the real TDLib message is visible in Console/`log show`
            // when diagnosing login failures (otherwise it's redacted as <private>).
            authLogger.error("TDLib auth error \(method.isEmpty ? "" : "[\(method)] ")code \(td.code): \(msg, privacy: .public)")
            let lower = msg.lowercased()
            if lower.contains("phone_code_invalid") || lower.contains("invalid code") || lower.contains("phone_code_expired") {
                return "The code you entered is incorrect or has expired. Tap Resend Code to get a new one."
            }
            if lower.contains("phone_number_invalid") {
                return "That phone number isn't valid — check the country code and the number."
            }
            if lower.contains("phone_number_banned") {
                return "This phone number is banned from Telegram."
            }
            if lower.contains("password_hash_invalid") || lower.contains("invalid password") {
                return "The password is incorrect — try again."
            }
            if lower.contains("flood") || lower.contains("too many") {
                return "Too many attempts — wait a minute, then try again."
            }
            if lower.contains("unexpected") {
                return "The login got out of sync — request a new code and try again."
            }
            return "\(msg) (\(td.code))"
        }
        return error.localizedDescription
    }

    // MARK: - User info

    struct AccountIdentity: Sendable {
        let id: Int64
        let firstName: String
        let lastName: String
        let username: String
        let phone: String
    }

    func fetchIdentity() async throws -> AccountIdentity {
        guard let client else { throw TelegramError.notInitialized }
        let user = try await client.getMe()
        let username = user.usernames?.editableUsername ?? user.usernames?.activeUsernames.first ?? ""
        return AccountIdentity(
            id: user.id,
            firstName: user.firstName,
            lastName: user.lastName,
            username: username,
            phone: user.phoneNumber
        )
    }

    func fetchProfilePhotoData() async throws -> Data? {
        guard let client else { throw TelegramError.notInitialized }
        let user = try await client.getMe()
        guard let photoFile = user.profilePhoto?.small else { return nil }
        let updated = try await client.downloadFile(
            fileId: photoFile.id, limit: 0, offset: 0, priority: 32, synchronous: true
        )
        let path = updated.local.path
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    func logout() async throws {
        guard let client else { throw TelegramError.notInitialized }
        try await client.logOut()
    }

    /// Fetches message either from local TDLib cache or directly from Telegram server if not cached.
    func getOrFetchMessage(chatId: Int64, messageId: Int64) async throws -> Message {
        guard let client else { throw TelegramError.notInitialized }
        if let msg = try? await client.getMessage(chatId: chatId, messageId: messageId) {
            return msg
        }
        if let res = try? await client.getMessages(chatId: chatId, messageIds: [messageId]),
           let msgs = res.messages, let first = msgs.compactMap({ $0 }).first {
            return first
        }
        // Force TDLib to sync recent channel history from server
        _ = try? await client.getChatHistory(chatId: chatId, fromMessageId: 0, limit: 100, offset: 0, onlyLocal: false)
        if let msg = try? await client.getMessage(chatId: chatId, messageId: messageId) {
            return msg
        }
        throw DownloadError.fileNotFound
    }

    func thumbnailFileId(forMessage messageId: Int64, chatId: Int64) async throws -> Int? {
        let message = try await getOrFetchMessage(chatId: chatId, messageId: messageId)
        switch message.content {
        case .messagePhoto(let ph):
            let best = ph.photo.sizes.min { abs($0.width - 320) < abs($1.width - 320) }
            return best?.photo.id
        case .messageVideo(let vid):
            return vid.video.thumbnail?.file.id
        case .messageDocument(let doc):
            return doc.document.thumbnail?.file.id
        case .messageAudio(let au):
            return au.audio.albumCoverThumbnail?.file.id
        default:
            return nil
        }
    }

    func thumbnailData(forMessage messageId: Int64, chatId: Int64) async throws -> Data? {
        let message = try await getOrFetchMessage(chatId: chatId, messageId: messageId)

        // 1. Try High-Resolution Thumbnail File FIRST
        if let fileId = try await thumbnailFileId(forMessage: messageId, chatId: chatId),
           let data = try await downloadFileData(fileId: fileId), !data.isEmpty {
            return data
        }

        // 2. Fallback to Embedded Minithumbnail Data ONLY if high-res file is absent
        switch message.content {
        case .messagePhoto(let ph):
            if let mini = ph.photo.minithumbnail { return mini.data }
        case .messageVideo(let vid):
            if let mini = vid.video.minithumbnail { return mini.data }
        case .messageDocument(let doc):
            if let mini = doc.document.minithumbnail { return mini.data }
        case .messageAudio(let au):
            if let mini = au.audio.albumCoverMinithumbnail { return mini.data }
        default:
            break
        }

        return nil
    }

    func downloadFileData(fileId: Int) async throws -> Data? {
        guard let client else { throw TelegramError.notInitialized }
        var file = try await client.downloadFile(
            fileId: fileId, limit: 0, offset: 0, priority: 32, synchronous: true
        )
        let startTime = Date()
        while !file.local.isDownloadingCompleted && Date().timeIntervalSince(startTime) < 5.0 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let updated = try? await client.getFile(fileId: fileId) {
                file = updated
            }
        }
        let path = file.local.path
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    func myUserID() async throws -> Int64 {
        guard let client else { throw TelegramError.notInitialized }
        let user = try await client.getMe()
        return user.id
    }

    // MARK: - Message file helpers

    enum MediaKind: Sendable {
        case photo
        case video
        case document
    }

    enum UploadStatus {
        case uploaded
        case notUploaded
        case unknown
    }

    /// Extracts the primary stored File from a message (document, video, or photo).
    private func primaryFile(from content: MessageContent) -> File? {
        switch content {
        case .messageDocument(let doc):
            return doc.document.document
        case .messageVideo(let vid):
            return vid.video.video
        case .messagePhoto(let ph):
            return ph.photo.sizes.max(by: { $0.width < $1.width })?.photo
        case .messageAudio(let au):
            // TDLib auto-converts .mp3 documents into audio messages unless
            // content-type detection is disabled (see InputDocument), so the
            // streaming engine must know audio messages too.
            return au.audio.audio
        default:
            return nil
        }
    }

    /// Debug hook (`--chunk-info <objectID>`): compare DB-recorded chunk sizes against
    /// what Telegram actually stores for each chunk message. A mismatch means the
    /// catalog points at the wrong document/size and streamed bytes will be garbage.
    func debugChunkInfo(objectID: String) async {
        let logURL = URL(fileURLWithPath: "/tmp/xcloud-chunkinfo.txt")
        func log(_ s: String) {
            print(s)
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile()
                h.write((s + "\n").data(using: .utf8) ?? Data())
                try? h.close()
            }
        }
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let obj = try? await DatabaseManager.shared.object(objectID),
              let vault = try? await DatabaseManager.shared.firstVault(),
              let chunks = try? await DatabaseManager.shared.chunks(for: objectID) else {
            log("xCloud debug: cannot load chunks for \(objectID)")
            return
        }
        log("xCloud debug: chunks for \(obj.name) (recorded total \(obj.size))")
        for (i, c) in chunks.enumerated() {
            guard let mid = c.messageID else { continue }
            do {
                let msg = try await getOrFetchMessage(chatId: vault.channelID, messageId: mid)
                if let file = primaryFile(from: msg.content) {
                    log("xCloud debug: chunk \(i) msg \(mid) db=\(c.size) tg=\(file.size) match=\(file.size == c.size)")
                } else {
                    log("xCloud debug: chunk \(i) msg \(mid) NO file in message")
                }
            } catch {
                log("xCloud debug: chunk \(i) msg \(mid) error \(error)")
            }
        }
    }

    func uploadStatus(chatId: Int64, messageId: Int64) async -> UploadStatus {
        do {
            let message = try await getOrFetchMessage(chatId: chatId, messageId: messageId)
            guard let file = primaryFile(from: message.content) else { return .notUploaded }
            return file.remote.isUploadingCompleted ? .uploaded : .notUploaded
        } catch {
            return .unknown
        }
    }

    /// Loads recent channel messages into the local cache so getMessage can find them.
    func fetchRecentMessages(chatId: Int64, limit: Int = 100) async {
        guard let client else { return }
        _ = try? await client.getChatHistory(
            chatId: chatId,
            fromMessageId: 0,
            limit: limit,
            offset: 0,
            onlyLocal: false
        )
    }

    // MARK: - Download

    func downloadMessageFile(
        messageId: Int64,
        chatId: Int64,
        to destination: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let message = try await getOrFetchMessage(chatId: chatId, messageId: messageId)
        guard let file = primaryFile(from: message.content) else {
            throw DownloadError.fileNotFound
        }

        if let onProgress {
            syncLock { fileDownloadProgressHandlers[file.id] = onProgress }
        }

        let updated = try await client?.downloadFile(
            fileId: file.id,
            limit: 0,
            offset: 0,
            priority: 32,
            synchronous: false
        )

        let localPath: String
        if let path = updated?.local.path, !path.isEmpty, updated?.local.isDownloadingCompleted == true {
            localPath = path
            onProgress?(1.0)
        } else {
            localPath = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    syncLock { fileDownloadContinuations[file.id] = continuation }
                    // Backstop: if TDLib never reports completion OR failure (a
                    // failed/superseded download can stop updating), resume with an
                    // error after 5 minutes so the caller fails cleanly instead of
                    // leaking the continuation and hanging forever.
                    let watchdog = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 300_000_000_000)
                        guard !Task.isCancelled else { return }
                        guard let self else { return }
                        let pending = self.syncLock { self.fileDownloadContinuations.removeValue(forKey: file.id) }
                        if pending != nil {
                            self.syncLock { self.fileDownloadWatchdogs.removeValue(forKey: file.id)?.cancel() }
                            pending?.resume(throwing: DownloadError.downloadFailed)
                        }
                    }
                    syncLock { fileDownloadWatchdogs[file.id] = watchdog }
                }
            } onCancel: {
                let continuation = syncLock {
                    fileDownloadContinuations.removeValue(forKey: file.id)
                }
                syncLock { fileDownloadWatchdogs.removeValue(forKey: file.id)?.cancel() }
                syncLock { fileDownloadProgressHandlers.removeValue(forKey: file.id) }
                continuation?.resume(throwing: CancellationError())
            }
            onProgress?(1.0)
        }

        if onProgress != nil {
            syncLock { fileDownloadProgressHandlers.removeValue(forKey: file.id) }
        }

        let dest = destination.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: dest) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: localPath), to: destination)
    }

    func getFileId(chatId: Int64, messageId: Int64) async throws -> Int {
        let message = try await getOrFetchMessage(chatId: chatId, messageId: messageId)
        guard let file = primaryFile(from: message.content) else {
            throw DownloadError.fileNotFound
        }
        return file.id
    }

    func fileId(forMessage messageId: Int64, chatId: Int64) async throws -> Int32 {
        let message = try await getOrFetchMessage(chatId: chatId, messageId: messageId)
        guard let file = primaryFile(from: message.content) else {
            throw DownloadError.fileNotFound
        }
        return Int32(file.id)
    }

    /// The actual byte size Telegram stores for a chunk document. The catalog's
    /// recorded chunk size can be stale (a chunk-plan change or interrupted upload
    /// writes a wrong record); the object's total usually still matches reality, so
    /// the stream layout must be built from the REAL sizes.
    func fileSize(forMessage messageId: Int64, chatId: Int64) async throws -> Int64? {
        let message = try await getOrFetchMessage(chatId: chatId, messageId: messageId)
        guard let file = primaryFile(from: message.content) else { return nil }
        return file.size
    }

    func fetchRange(fileId: Int, offset: Int64, limit: Int64) async throws -> String {
        guard let client else { throw TelegramError.notInitialized }
        let file = try await client.downloadFile(
            fileId: fileId,
            limit: limit,
            offset: offset,
            priority: 16,
            synchronous: true
        )
        return file.local.path
    }

    /// Downloads an exact byte range of a file — TDLib's media-streaming range support
    /// (added for "downloading any part of a file") — and returns those bytes. The
    /// `synchronous: true` call returns once the range is on disk, so it blocks only the
    /// calling Task's thread, never the main thread. Callers must serialize range
    /// requests per file: TDLib lets a new downloadFile with a different offset/limit
    /// supersede an in-flight one for the same file.
    func fetchRangeData(
        fileId: Int,
        offset: Int64,
        limit: Int64,
        priority: Int = 32
    ) async throws -> Data {
        guard let client else { throw TelegramError.notInitialized }
        let file = try await client.downloadFile(
            fileId: fileId,
            limit: limit,
            offset: offset,
            priority: priority,
            synchronous: true
        )
        let path = file.local.path
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            throw DownloadError.fileNotFound
        }
        // TDLib writes a ranged download at its ORIGINAL offset in the persistent local
        // file for that fileId, leaving the bytes before it sparse — so the on-disk file
        // can be as large as the whole chunk (128 MB) even though only `limit` bytes were
        // actually fetched. Reading the whole file (Data(contentsOf:)) allocates up to
        // the chunk size per slice; once the slice cache holds several of those, the
        // process balloons to gigabytes (observed: 7 GB while streaming). Read exactly
        // the requested range instead, so every fetch is bounded by `limit` (~1 MB).
        let url = URL(fileURLWithPath: path)
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? Int64(limit)
        // Range-at-original-offset (sparse file) vs range-at-start (fresh file): pick
        // whichever layout TDLib actually produced on disk.
        let readOffset: Int64 = (fileSize >= offset + limit) ? offset : 0
        let readLength = min(Int(limit), max(0, Int(fileSize - readOffset)))
        guard readLength > 0 else { throw DownloadError.fileNotFound }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(readOffset))
        return handle.readData(ofLength: readLength)
    }

    // MARK: - Storage operations

    func createVaultChannel(title: String) async throws -> Int64 {
        guard let client else { throw TelegramError.notInitialized }
        let chat = try await client.createNewSupergroupChat(
            description: "xCloud storage",
            forImport: false,
            isChannel: true,
            isForum: false,
            location: nil as ChatLocation?,
            messageAutoDeleteTime: 0,
            title: title
        )
        return chat.id
    }

    /// Hides the vault channel from the Telegram chat list (archived) so users never
    /// stumble into it and mess with the storage messages. Archiving alone isn't
    /// enough — TDLib automatically moves an UNMUTED archived chat back to the main
    /// list when a new message arrives (which happens constantly), so the channel is
    /// also muted forever. Best-effort: failures are logged, never fatal.
    func archiveVaultChannel(chatId: Int64) async {
        guard let client else { return }
        do {
            try await client.addChatToList(chatId: chatId, chatList: .chatListArchive)
            let muted = ChatNotificationSettings(
                disableMentionNotifications: true,
                disablePinnedMessageNotifications: true,
                // Mute for >366 days = muted forever (TDLib clamps it).
                muteFor: 367 * 24 * 60 * 60,
                muteStories: true,
                showPreview: false,
                showStoryPoster: false,
                soundId: 0,
                storySoundId: 0,
                useDefaultDisableMentionNotifications: false,
                useDefaultDisablePinnedMessageNotifications: false,
                useDefaultMuteFor: false,
                useDefaultMuteStories: false,
                useDefaultShowPreview: false,
                useDefaultShowStoryPoster: false,
                useDefaultSound: false,
                useDefaultStorySound: false
            )
            try await client.setChatNotificationSettings(
                chatId: chatId,
                notificationSettings: muted
            )
            logger.info("Vault channel \(chatId) archived and muted")
        } catch {
            logger.info("Vault channel archive failed: \(error.localizedDescription)")
        }
    }

    /// Looks for an existing "xCloud Vault" channel owned by this account so that
    /// logging in on a new device adopts the real vault instead of silently creating a
    /// brand-new empty channel (which is why files "disappear" after a fresh install).
    /// Searches the local chat list first, then the server, then pages the main chat
    /// list as a fallback. Returns nil when the account has no vault channel yet.
    func findVaultChannel() async -> Int64? {
        await findChannel(title: "xCloud Vault")
    }

    /// Same discovery as `findVaultChannel` but for the "xCloud Backup" channel
    /// (Engine/BackupSync.swift mirrors every vault message into it). Adopts an
    /// older "xCloud Restore" channel if present and renames it to the new title.
    func findBackupChannel() async -> Int64? {
        if let id = await findChannel(title: "xCloud Backup") {
            return id
        }
        if let id = await findChannel(title: "xCloud Restore") {
            try? await client?.setChatTitle(chatId: id, title: "xCloud Backup")
            return id
        }
        return nil
    }

    /// Generic channel-by-title discovery: local search first, then server search,
    /// then a page of the main chat list. Retries a few times right after login
    /// because TDLib may not have synced the chat list yet.
    func findChannel(title: String) async -> Int64? {
        guard let client else { return nil }

        // Right after login TDLib may not have synced the chat list yet, so retry a
        // few times with a short pause before giving up and creating a new channel.
        for attempt in 1...3 {
            if let found = await findChannelOnce(title: title) {
                return found
            }
            if attempt < 3 {
                logger.info("Channel '\(title)' not found (attempt \(attempt)/3), retrying…")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        logger.info("No existing channel '\(title)' found for this account")
        return nil
    }

    private func findChannelOnce(title: String) async -> Int64? {
        guard let client else { return nil }

        let candidates = [
            try? await client.searchChats(
                limit: 10,
                query: title,
                typeFilter: .searchChatTypeFilterChannel
            ),
            try? await client.searchChatsOnServer(
                limit: 10,
                query: title,
                typeFilter: .searchChatTypeFilterChannel
            ),
        ]

        for chats in candidates.compactMap({ $0 }) {
            for id in chats.chatIds {
                if await isChannelNamed(id: id, title: title) { return id }
            }
        }

        // Fallback: the channel lives in the user's own chat list even if the title
        // search missed it — page the beginning of the main chat list.
        if let chats = try? await client.getChats(chatList: nil, limit: 200) {
            for id in chats.chatIds {
                if await isChannelNamed(id: id, title: title) { return id }
            }
        }

        return nil
    }

    /// Finds the latest `xcloud:vaultkey:` recovery message in the channel. Its
    /// caption carries the vault key sealed with the PIN-derived key, enabling
    /// cross-device recovery of private files.
    func findRecoveryBlob(chatId: Int64) async -> Message? {
        guard let client else { return nil }
        let messages = await allChannelMessages(chatId: chatId)
        var latest: Message?
        for message in messages {
            let text: String?
            switch message.content {
            case .messageText(let mt): text = mt.text.text
            case .messageDocument(let doc): text = doc.caption.text
            default: text = nil
            }
            if let text, text.hasPrefix("xcloud:vaultkey:") {
                latest = message
            }
        }
        return latest
    }

    private func isChannelNamed(id: Int64, title: String) async -> Bool {
        guard let client, let chat = try? await client.getChat(chatId: id) else { return false }
        guard chat.title == title else { return false }
        if case .chatTypeSupergroup(let sg) = chat.type, sg.isChannel {
            return true
        }
        return false
    }

    func withFloodWait<T>(_ action: @escaping () async throws -> T) async throws -> T {
        while true {
            do {
                return try await action()
            } catch {
                let msg = "\(error)".lowercased()
                // TDLib errors look like: "Error 429: FLOOD_WAIT_5"
                if let range = msg.range(of: "flood_wait_(\\d+)", options: .regularExpression) {
                    let numStr = msg[range].filter { $0.isNumber }
                    if let seconds = Int(numStr) {
                        logger.warning("Flood wait triggered, sleeping for \(seconds)s")
                        try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000 + 500_000_000)
                        continue
                    }
                }
                throw error
            }
        }
    }

    func uploadFile(path: String, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> Int {
        guard let client else { throw TelegramError.notInitialized }

        let file = try await client.preliminaryUploadFile(
            file: .inputFileLocal(InputFileLocal(path: path)),
            fileType: .fileTypeDocument,
            priority: 32
        )

        if file.remote.isUploadingCompleted {
            onProgress?(1.0)
            return file.id
        }

        if let onProgress {
            syncLock { fileUploadProgressHandlers[file.id] = onProgress }
        }

        let completedFileId = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                syncLock { fileUploadContinuations[file.id] = continuation }
            }
        } onCancel: {
            // Abort immediately: drop the continuation (and progress handler) so a
            // cancelled upload never posts a message for the abandoned chunk.
            let continuation = syncLock {
                fileUploadContinuations.removeValue(forKey: file.id)
            }
            syncLock { fileUploadProgressHandlers.removeValue(forKey: file.id) }
            continuation?.resume(throwing: CancellationError())
        }

        if onProgress != nil {
            syncLock { fileUploadProgressHandlers.removeValue(forKey: file.id) }
        }

        onProgress?(1.0)
        return completedFileId
    }

    func sendFile(
        chatId: Int64,
        path: String,
        kind: MediaKind,
        caption: String? = nil,
        thumbnailPath: String? = nil,
        protectContent: Bool = true,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Int64 {
        guard let client else { throw TelegramError.notInitialized }

        // Step 1: Upload the file and track real-time byte-level upload progress via updateFile
        let fileId = try await uploadFile(path: path, onProgress: onProgress)

        // Step 2: Post the message attaching the uploaded inputFileId.
        // When a thumbnailPath is supplied (uploaded via the local JPEG the engine
        // generates), Telegram permanently stores that thumbnail with the message —
        // so after the app's local cache is cleared, the preview can always be
        // re-fetched from Telegram instead of being gone forever.
        let inputThumbnail: InputThumbnail? = thumbnailPath.map {
            InputThumbnail(
                height: 0,
                thumbnail: .inputFileLocal(InputFileLocal(path: $0)),
                width: 0
            )
        }
        let formattedCaption: FormattedText? = caption.map { FormattedText(entities: [], text: $0) }
        let content: InputMessageContent
        switch kind {
        case .photo:
            let inputPhoto = InputPhoto(
                addedStickerFileIds: [],
                height: 0,
                photo: .inputFileId(InputFileId(id: fileId)),
                thumbnail: inputThumbnail,
                video: nil as InputFile?,
                width: 0
            )
            content = .inputMessagePhoto(InputMessagePhoto(
                caption: formattedCaption,
                hasSpoiler: false,
                photo: inputPhoto,
                selfDestructType: nil as MessageSelfDestructType?,
                showCaptionAboveMedia: false
            ))
        case .video:
            let inputVideo = InputVideo(
                addedStickerFileIds: [],
                cover: nil as InputFile?,
                duration: 0,
                height: 0,
                startTimestamp: 0,
                supportsStreaming: true,
                thumbnail: inputThumbnail,
                video: .inputFileId(InputFileId(id: fileId)),
                width: 0
            )
            content = .inputMessageVideo(InputMessageVideo(
                caption: formattedCaption,
                hasSpoiler: false,
                selfDestructType: nil as MessageSelfDestructType?,
                showCaptionAboveMedia: false,
                video: inputVideo
            ))
        case .document:
            let inputDocument = InputDocument(
                // TDLib's default content-type detection converts e.g. .mp3 chunk
                // documents into audio messages (and images into photos), which the
                // app's streaming/thumbnail code doesn't expect — always send as a
                // plain document so every chunk behaves identically.
                disableContentTypeDetection: true,
                document: .inputFileId(InputFileId(id: fileId)),
                thumbnail: inputThumbnail
            )
            content = .inputMessageDocument(InputMessageDocument(
                caption: formattedCaption,
                document: inputDocument
            ))
        }

        let message = try await withFloodWait {
            try await client.sendMessage(
                chatId: chatId,
                inputMessageContent: content,
                options: MessageSendOptions(
                    allowPaidBroadcast: false,
                    disableNotification: true,
                    effectId: 0,
                    fromBackground: false,
                    onlyPreview: false,
                    paidMessageStarCount: 0,
                    protectContent: protectContent,
                    schedulingState: nil as MessageSchedulingState?,
                    sendingId: 0,
                    suggestedPostInfo: nil as InputSuggestedPostInfo?,
                    updateOrderOfInstalledStickerSets: false
                ),
                replyMarkup: nil as ReplyMarkup?,
                replyTo: nil as InputMessageReplyTo?,
                topicId: nil as MessageTopic?
            )
        }

        if message.sendingState == nil {
            return message.id
        }

        let preResult = syncLock { completedSends.removeValue(forKey: message.id) }
        if let preResult {
            return try preResult.get()
        }

        // Bound the stale-result cache left behind by cancelled sends.
        syncLock {
            if completedSends.count > 64 {
                completedSends = Dictionary(completedSends.suffix(32), uniquingKeysWith: { first, _ in first })
            }
        }

        let finalId = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                syncLock { pendingSendContinuations[message.id] = continuation }
            }
        } onCancel: {
            // Abort immediately: if the message hasn't been confirmed yet, drop the
            // continuation so the cancelled send throws instead of waiting.
            let continuation = syncLock {
                pendingSendContinuations.removeValue(forKey: message.id)
            }
            continuation?.resume(throwing: CancellationError())
        }
        return finalId
    }

    // MARK: - Channel maintenance

    func allChannelMessages(chatId: Int64) async -> [Message] {
        guard let client else { return [] }
        var result: [Message] = []
        var from: Int64 = 0
        var page = 0
        while page < 2000 {
            page += 1
            // TDLib may return FEWER than the limit even when older messages exist
            // ("the number of returned messages is chosen by TDLib"), so we must not
            // stop on a short page — keep paging until no strictly-older messages
            // come back. A negative offset on later pages asks for messages preceding
            // the last one we received.
            let offset = page == 1 ? 0 : -1
            guard let history = try? await client.getChatHistory(
                chatId: chatId,
                fromMessageId: from,
                limit: 100,
                offset: offset,
                onlyLocal: false
            ), let msgs = history.messages, !msgs.isEmpty else { break }

            // Dedup in case a page overlaps the previous one.
            let minSeen = result.last?.id ?? Int64.max
            let newOnes = msgs.filter { $0.id < minSeen }
            guard !newOnes.isEmpty else { break }

            result.append(contentsOf: newOnes)
            from = newOnes.last?.id ?? 0
            if from == 0 { break }
        }
        return result
    }

    func allChannelMessageIDs(chatId: Int64) async -> [Int64] {
        let msgs = await allChannelMessages(chatId: chatId)
        return msgs.map(\.id)
    }

    func deleteMessages(chatId: Int64, messageIds: [Int64]) async throws {
        guard let client else { throw TelegramError.notInitialized }
        try await client.deleteMessages(chatId: chatId, messageIds: messageIds, revoke: true)
    }

    func editMessageCaption(chatId: Int64, messageId: Int64, caption: String) async throws {
        guard let client else { throw TelegramError.notInitialized }
        let formattedText = FormattedText(entities: [], text: caption)
        try await client.editMessageCaption(
            caption: formattedText,
            chatId: chatId,
            messageId: messageId,
            replyMarkup: nil,
            showCaptionAboveMedia: false
        )
    }

    func sendMetadataMessage(chatId: Int64, text: String) async throws -> Int64? {
        guard let client else { throw TelegramError.notInitialized }
        let content = InputMessageContent.inputMessageText(InputMessageText(
            clearDraft: false,
            linkPreviewOptions: nil,
            text: FormattedText(entities: [], text: text)
        ))
        let msg = try await client.sendMessage(
            chatId: chatId,
            inputMessageContent: content,
            options: MessageSendOptions(
                allowPaidBroadcast: false,
                disableNotification: true,
                effectId: 0,
                fromBackground: false,
                onlyPreview: false,
                paidMessageStarCount: 0,
                protectContent: true,
                schedulingState: nil as MessageSchedulingState?,
                sendingId: 0,
                suggestedPostInfo: nil as InputSuggestedPostInfo?,
                updateOrderOfInstalledStickerSets: false
            ),
            replyMarkup: nil as ReplyMarkup?,
            replyTo: nil as InputMessageReplyTo?,
            topicId: nil as MessageTopic?
        )
        return msg.id
    }

    // MARK: - Cloud sharing (channels)

    /// Creates a private channel (joinable only via its invite link) that carries
    /// one shared file, and returns its chat id.
    func createShareChannel(title: String) async throws -> Int64 {
        guard let client else { throw TelegramError.notInitialized }
        let chat = try await client.createNewSupergroupChat(
            description: nil,
            forImport: false,
            isChannel: true,
            isForum: false,
            location: nil as ChatLocation?,
            messageAutoDeleteTime: 0,
            title: title
        )
        return chat.id
    }

    /// One-use invite link (memberLimit 1) so only the link holder can join.
    func createShareInviteLink(chatId: Int64, expiresIn: TimeInterval) async throws -> String {
        guard let client else { throw TelegramError.notInitialized }
        let link = try await client.createChatInviteLink(
            chatId: chatId,
            createsJoinRequest: false,
            expirationDate: Int(Date().timeIntervalSince1970) + Int(expiresIn),
            memberLimit: 1,
            name: "xCloud share"
        )
        return link.inviteLink
    }

    func checkShareInviteLink(_ inviteLink: String) async throws -> ChatInviteLinkInfo {
        guard let client else { throw TelegramError.notInitialized }
        return try await client.checkChatInviteLink(inviteLink: inviteLink)
    }

    func joinShareChannel(inviteLink: String) async throws -> Int64 {
        guard let client else { throw TelegramError.notInitialized }
        let result = try await client.joinChatByInviteLink(inviteLink: inviteLink)
        switch result {
        case .chatJoinResultSuccess(let success):
            return success.chatId
        case .chatJoinResultRequestSent, .chatJoinResultDeclined, .chatJoinResultGuardBotApprovalRequired:
            throw TelegramError.joinFailed("The share link could not be joined (request pending or declined).")
        }
    }

    /// True when the current user is already a member of the chat (false on any
    /// error). Lets the recipient recover when a one-use share invite was already
    /// consumed by another join — e.g. the link was opened in the browser first —
    /// by reaching the channel directly through the chat id carried in the link.
    func isChatMember(chatId: Int64) async throws -> Bool {
        guard let client else { throw TelegramError.notInitialized }
        return await chatExists(chatId: chatId)
    }

    /// True when the current user can still see the chat (it exists and wasn't
    /// deleted). Served from TDLib's local chat cache, so it's cheap. Used to
    /// verify a share channel is still alive before reusing its link — a share
    /// record can outlive its channel if the channel was deleted out-of-band
    /// (e.g. manually in Telegram, or a crash between deleteChat and the record
    /// being marked revoked).
    func chatExists(chatId: Int64) async -> Bool {
        guard let client else { return false }
        do {
            _ = try await client.getChat(chatId: chatId)
            return true
        } catch {
            return false
        }
    }

    /// Reads the share channel's messages (newest first) and returns those whose
    /// caption carries the xCloud share prefix, ordered by message id ascending.
    func shareChannelMessages(chatId: Int64, prefix: String) async throws -> [(messageId: Int64, caption: String)] {
        guard let client else { throw TelegramError.notInitialized }
        var result: [(messageId: Int64, caption: String)] = []
        var fromMessageId: Int64 = 0
        while true {
            let history = try await client.getChatHistory(
                chatId: chatId,
                fromMessageId: fromMessageId,
                limit: 100,
                offset: 0,
                onlyLocal: false
            )
            let messages = history.messages ?? []
            if messages.isEmpty { break }
            for message in messages {
                if let caption = messageCaption(message), caption.hasPrefix(prefix) {
                    result.append((message.id, caption))
                }
            }
            let oldest = messages.map(\.id).min() ?? 0
            let newest = messages.map(\.id).max() ?? 0
            if newest <= fromMessageId || messages.count < 100 {
                break
            }
            fromMessageId = oldest - 1
        }
        return result.sorted { $0.messageId < $1.messageId }
    }

    /// Reads specific messages of a chat by ID, preserving the given order, with
    /// their captions. Used by forward-based share imports — the link carries the
    /// exact forwarded message IDs, and the reusable share channel can hold many
    /// files at once, so the recipient targets only its own messages.
    func messagesByIds(chatId: Int64, messageIds: [Int64]) async throws -> [(messageId: Int64, caption: String?)] {
        guard let client else { throw TelegramError.notInitialized }
        var result: [(messageId: Int64, caption: String?)] = []
        for id in messageIds {
            let message = try await client.getMessage(chatId: chatId, messageId: id)
            result.append((message.id, messageCaption(message)))
        }
        return result
    }

    /// Extracts the caption text of a message (document caption, not just text-only).
    private func messageCaption(_ message: Message) -> String? {
        switch message.content {
        case .messageText(let text):
            return text.text.text
        case .messageDocument(let doc):
            return doc.caption.text
        case .messagePhoto(let photo):
            return photo.caption.text
        case .messageVideo(let video):
            return video.caption.text
        case .messageAudio(let audio):
            return audio.caption.text
        default:
            return nil
        }
    }

    /// Debug hook: writes any chat's full message list (id, kind, caption) to
    /// /tmp/xcloud-chat-<id>.txt so real channel state can be inspected.
    func debugDumpChat(chatId: Int64) async throws {
        guard let client else { throw TelegramError.notInitialized }
        var lines: [String] = []
        var fromMessageId: Int64 = 0
        while true {
            let history = try await client.getChatHistory(
                chatId: chatId,
                fromMessageId: fromMessageId,
                limit: 100,
                offset: 0,
                onlyLocal: false
            )
            let messages = history.messages ?? []
            if messages.isEmpty { break }
            for message in messages {
                var kind = "other"
                var caption = ""
                switch message.content {
                case .messageDocument(let doc):
                    kind = "doc(\(doc.document.fileName))"
                    caption = doc.caption.text
                case .messagePhoto(let photo):
                    kind = "photo"
                    caption = photo.caption.text
                case .messageVideo(let video):
                    kind = "video"
                    caption = video.caption.text
                case .messageAudio(let audio):
                    kind = "audio"
                    caption = audio.caption.text
                case .messageText(let text):
                    kind = "text"
                    caption = text.text.text
                default:
                    kind = "other"
                }
                lines.append("\(message.id)\t\(kind)\t\(caption)")
            }
            let oldest = messages.map(\.id).min() ?? 0
            let newest = messages.map(\.id).max() ?? 0
            if newest <= fromMessageId || messages.count < 100 { break }
            fromMessageId = oldest - 1
        }
        try? lines.joined(separator: "\n").write(
            toFile: "/tmp/xcloud-chat-\(chatId).txt",
            atomically: true,
            encoding: .utf8
        )
        print("xCloud debug: dumped \(lines.count) message(s) of chat \(chatId)")
    }

    /// Forwards a message into another chat and returns the new message id.
    func forwardMessage(chatId: Int64, fromChatId: Int64, messageId: Int64) async throws -> Int64 {
        guard let client else { throw TelegramError.notInitialized }
        let result = try await client.forwardMessages(
            chatId: chatId,
            fromChatId: fromChatId,
            messageIds: [messageId],
            options: MessageSendOptions(
                allowPaidBroadcast: false,
                disableNotification: true,
                effectId: 0,
                fromBackground: false,
                onlyPreview: false,
                paidMessageStarCount: 0,
                protectContent: true,
                schedulingState: nil as MessageSchedulingState?,
                sendingId: 0,
                suggestedPostInfo: nil as InputSuggestedPostInfo?,
                updateOrderOfInstalledStickerSets: false
            ),
            removeCaption: false,
            sendCopy: false,
            topicId: nil as MessageTopic?
        )
        return result.messages?.first?.id ?? 0
    }

    func leaveChat(chatId: Int64) async throws {
        guard let client else { throw TelegramError.notInitialized }
        _ = try await client.leaveChat(chatId: chatId)
    }

    /// Deletes the share channel (creator only) — used by the expiry cleanup loop.
    func deleteChat(chatId: Int64) async throws {
        guard let client else { throw TelegramError.notInitialized }
        _ = try await client.deleteChat(chatId: chatId)
    }

    // MARK: - Paths

    private func databasePath() -> String {
        let fm = FileManager.default
        let support = try! fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = support.appendingPathComponent("xCloud/tdlib", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.path(percentEncoded: false)
    }

    private func filesPath() -> String {
        let fm = FileManager.default
        let cache = try! fm.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = cache.appendingPathComponent("xCloud/tdlib-files", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.path(percentEncoded: false)
    }
}
