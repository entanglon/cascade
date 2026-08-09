import Foundation
import TDLibKit
import os

enum TelegramError: Swift.Error, Sendable {
    case notInitialized
}

enum TelegramAuthStep: String, Sendable {
    case phone
    case code
    case password
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
                    case "authorizationStateWaitCode":
                        self.authStep = .code
                        self.isConnected = true
                        self.isAuthorized = false
                    case "authorizationStateWaitPassword":
                        self.authStep = .password
                        self.isConnected = true
                        self.isAuthorized = false
                    case "authorizationStateReady":
                        self.authStep = .ready
                        self.isConnected = true
                        self.isAuthorized = true
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

                    if isCompleted && !path.isEmpty {
                        let continuation = syncLock { fileDownloadContinuations.removeValue(forKey: fileId) }
                        continuation?.resume(returning: path)
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
        default:
            return nil
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
                }
            } onCancel: {
                let continuation = syncLock {
                    fileDownloadContinuations.removeValue(forKey: file.id)
                }
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
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Int64 {
        guard let client else { throw TelegramError.notInitialized }

        // Step 1: Upload the file and track real-time byte-level upload progress via updateFile
        let fileId = try await uploadFile(path: path, onProgress: onProgress)

        // Step 2: Post the message attaching the uploaded inputFileId
        let formattedCaption: FormattedText? = caption.map { FormattedText(entities: [], text: $0) }
        let content: InputMessageContent
        switch kind {
        case .photo:
            let inputPhoto = InputPhoto(
                addedStickerFileIds: [],
                height: 0,
                photo: .inputFileId(InputFileId(id: fileId)),
                thumbnail: nil as InputThumbnail?,
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
                thumbnail: nil as InputThumbnail?,
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
                disableContentTypeDetection: false,
                document: .inputFileId(InputFileId(id: fileId)),
                thumbnail: nil as InputThumbnail?
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
        while true {
            guard let history = try? await client.getChatHistory(
                chatId: chatId,
                fromMessageId: from,
                limit: 100,
                offset: 0,
                onlyLocal: false
            ), let msgs = history.messages, !msgs.isEmpty else { break }

            result.append(contentsOf: msgs)
            if msgs.count < 100 { break }
            from = msgs.last?.id ?? 0
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
