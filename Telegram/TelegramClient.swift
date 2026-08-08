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
    private var pendingSendContinuations: [Int64: CheckedContinuation<Int64, any Swift.Error>] = [:]
    private var completedSends: [Int64: Result<Int64, any Swift.Error>] = [:]
    private var fileProgressHandlers: [Int: (Double) -> Void] = [:]
    private let trackingLock = NSLock()

    // MARK: - Update handling

    private func handleUpdate(data: Data) async {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["@type"] as? String else { return }

        switch type {
        case "updateAuthorizationState":
            if let authState = json["authorization_state"] as? [String: Any],
               let stateType = authState["@type"] as? String {
                await MainActor.run {
                    switch stateType {
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
                trackingLock.lock()
                let handler = fileProgressHandlers[fileId]
                trackingLock.unlock()

                if let handler {
                    let expectedSize = (file["expected_size"] as? NSNumber)?.doubleValue ?? 0
                    if expectedSize > 0 {
                        var current: Double = 0
                        if let remote = file["remote"] as? [String: Any],
                           let uploaded = (remote["uploaded_size"] as? NSNumber)?.doubleValue {
                            current = max(current, uploaded)
                        }
                        if let local = file["local"] as? [String: Any],
                           let downloaded = (local["downloaded_size"] as? NSNumber)?.doubleValue {
                            current = max(current, downloaded)
                        }
                        handler(min(current / expectedSize, 1.0))
                    }
                }
            }

        case "updateMessageSendSucceeded":
            if let oldId = (json["old_message_id"] as? NSNumber)?.int64Value,
               let message = json["message"] as? [String: Any],
               let realId = (message["id"] as? NSNumber)?.int64Value {
                trackingLock.lock()
                if let continuation = pendingSendContinuations.removeValue(forKey: oldId) {
                    trackingLock.unlock()
                    continuation.resume(returning: realId)
                } else {
                    completedSends[oldId] = .success(realId)
                    trackingLock.unlock()
                }
            }

        case "updateMessageSendFailed":
            if let oldId = (json["old_message_id"] as? NSNumber)?.int64Value {
                let code = (json["error_code"] as? NSNumber)?.intValue ?? 0
                let msg = (json["error_message"] as? String) ?? "Upload failed"
                let err: any Swift.Error = NSError(domain: "Telegram", code: code, userInfo: [NSLocalizedDescriptionKey: msg])
                trackingLock.lock()
                if let continuation = pendingSendContinuations.removeValue(forKey: oldId) {
                    trackingLock.unlock()
                    continuation.resume(throwing: err)
                } else {
                    completedSends[oldId] = .failure(err)
                    trackingLock.unlock()
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

    func thumbnailFileId(forMessage messageId: Int64, chatId: Int64) async throws -> Int? {
        guard let client else { throw TelegramError.notInitialized }
        let message = try await client.getMessage(chatId: chatId, messageId: messageId)
        switch message.content {
        case .messagePhoto(let ph):
            let best = ph.photo.sizes.min { abs($0.width - 320) < abs($1.width - 320) }
            return best?.photo.id
        case .messageVideo(let vid):
            return vid.video.thumbnail?.file.id
        default:
            return nil
        }
    }

    func downloadFileData(fileId: Int) async throws -> Data? {
        guard let client else { throw TelegramError.notInitialized }
        let updated = try await client.downloadFile(
            fileId: fileId, limit: 0, offset: 0, priority: 32, synchronous: true
        )
        let path = updated.local.path
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
        guard let client else { return .unknown }
        do {
            let message = try await client.getMessage(chatId: chatId, messageId: messageId)
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

    func downloadMessageFile(messageId: Int64, chatId: Int64, to destination: URL) async throws {
        guard let client else { throw TelegramError.notInitialized }
        let message = try await client.getMessage(chatId: chatId, messageId: messageId)
        guard let file = primaryFile(from: message.content) else {
            throw DownloadError.fileNotFound
        }

        let updated = try await client.downloadFile(
            fileId: file.id,
            limit: 0,
            offset: 0,
            priority: 32,
            synchronous: true
        )
        let path = updated.local.path
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            throw DownloadError.fileNotFound
        }
        let dest = destination.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: dest) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: destination)
    }

    func getFileId(chatId: Int64, messageId: Int64) async throws -> Int {
        guard let client else { throw TelegramError.notInitialized }
        let message = try await client.getMessage(chatId: chatId, messageId: messageId)
        guard let file = primaryFile(from: message.content) else {
            throw DownloadError.fileNotFound
        }
        return file.id
    }

    func fileId(forMessage messageId: Int64, chatId: Int64) async throws -> Int32 {
        guard let client else { throw TelegramError.notInitialized }
        let message = try await client.getMessage(chatId: chatId, messageId: messageId)
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

    func sendFile(
        chatId: Int64,
        path: String,
        kind: MediaKind,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Int64 {
        guard let client else { throw TelegramError.notInitialized }

        let content: InputMessageContent
        switch kind {
        case .photo:
            let inputPhoto = InputPhoto(
                addedStickerFileIds: [],
                height: 0,
                photo: .inputFileLocal(InputFileLocal(path: path)),
                thumbnail: nil as InputThumbnail?,
                video: nil as InputFile?,
                width: 0
            )
            content = .inputMessagePhoto(InputMessagePhoto(
                caption: nil as FormattedText?,
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
                video: .inputFileLocal(InputFileLocal(path: path)),
                width: 0
            )
            content = .inputMessageVideo(InputMessageVideo(
                caption: nil as FormattedText?,
                hasSpoiler: false,
                selfDestructType: nil as MessageSelfDestructType?,
                showCaptionAboveMedia: false,
                video: inputVideo
            ))
        case .document:
            let inputDocument = InputDocument(
                disableContentTypeDetection: false,
                document: .inputFileLocal(InputFileLocal(path: path)),
                thumbnail: nil as InputThumbnail?
            )
            content = .inputMessageDocument(InputMessageDocument(
                caption: nil as FormattedText?,
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

        // If message send already finished instantly
        if message.sendingState == nil {
            onProgress?(1.0)
            return message.id
        }

        let fileId = primaryFile(from: message.content)?.id

        if let fileId, let onProgress {
            trackingLock.lock()
            fileProgressHandlers[fileId] = onProgress
            trackingLock.unlock()
        }

        // Check if send succeeded before setup
        trackingLock.lock()
        if let preResult = completedSends.removeValue(forKey: message.id) {
            if let fileId { fileProgressHandlers.removeValue(forKey: fileId) }
            trackingLock.unlock()
            onProgress?(1.0)
            return try preResult.get()
        }
        trackingLock.unlock()

        // Wait for updateMessageSendSucceeded
        let finalId = try await withCheckedThrowingContinuation { continuation in
            trackingLock.lock()
            pendingSendContinuations[message.id] = continuation
            trackingLock.unlock()
        }

        if let fileId {
            trackingLock.lock()
            fileProgressHandlers.removeValue(forKey: fileId)
            trackingLock.unlock()
        }

        onProgress?(1.0)
        return finalId
    }

    // MARK: - Channel maintenance

    func allChannelMessageIDs(chatId: Int64) async -> [Int64] {
        guard let client else { return [] }
        var ids: [Int64] = []
        var from: Int64 = 0
        while true {
            guard let history = try? await client.getChatHistory(
                chatId: chatId,
                fromMessageId: from,
                limit: 100,
                offset: 0,
                onlyLocal: false
            ) else { break }

            var batch: [Int64] = []
            for message in history.messages ?? [] {
                batch.append(message.id)
            }

            ids.append(contentsOf: batch)
            if batch.count < 100 { break }
            from = batch.last ?? 0
        }
        return ids
    }

    func deleteMessages(chatId: Int64, messageIds: [Int64]) async throws {
        guard let client else { throw TelegramError.notInitialized }
        try await client.deleteMessages(chatId: chatId, messageIds: messageIds, revoke: true)
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
