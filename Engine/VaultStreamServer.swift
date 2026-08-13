import Foundation
import Network

/// A loopback-only HTTP/1.1 server that serves decrypted vault bytes to mpv.
///
/// mpv (via FFmpeg's libavformat) demuxes any container itself — mkv, webm, avi,
/// ts, flv, ... — but it needs a byte-range-capable HTTP source to seek. This
/// server maps `GET /stream/<objectID>` (optionally with a `Range:` header) onto
/// the same 1 MB slice fetch/decrypt pipeline the AVFoundation streaming engine
/// uses, so formats AVFoundation can't range-demux stream through mpv instead.
///
/// The listener is bound to 127.0.0.1 only and the response carries
/// `Cache-Control: no-store`, so decrypted plaintext never touches disk.
final class VaultStreamServer {
    static let shared = VaultStreamServer()

    private static let queue = DispatchQueue(label: "com.xcloud.vaultstream", qos: .userInitiated)

    private let lock = NSLock()
    private var listener: NWListener?
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var port: UInt16 = 0
    private var isReady = false

    private init() {}

    /// The loopback URL mpv should play for `objectID`, starting the server if
    /// needed. Returns nil if the server failed to come up.
    func streamURL(for objectID: String) async -> URL? {
        await startIfNeeded()
        lock.lock(); defer { lock.unlock() }
        guard isReady, port > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/stream/\(objectID)")
    }

    // MARK: - Server lifecycle

    private func startIfNeeded() async {
        lock.lock()
        if listener == nil, !isReady {
            do {
                let params = NWParameters.tcp
                // Bind loopback only — decrypted bytes must never leave the machine.
                params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 0)
                let listener = try NWListener(using: params)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handleConnection(connection)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    self?.handleState(state)
                }
                self.listener = listener
                listener.start(queue: Self.queue)
            } catch {
                listener = nil
            }
        }
        lock.unlock()

        if !isReady {
            await withCheckedContinuation { continuation in
                lock.lock()
                if isReady {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                readyWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func handleState(_ state: NWListener.State) {
        lock.lock()
        switch state {
        case .ready:
            isReady = true
            port = listener?.port?.rawValue ?? 0
            let waiters = readyWaiters
            readyWaiters.removeAll()
            lock.unlock()
            waiters.forEach { $0.resume() }
        case .failed, .cancelled:
            isReady = false
            listener = nil
            let waiters = readyWaiters
            readyWaiters.removeAll()
            lock.unlock()
            waiters.forEach { $0.resume() }
        default:
            lock.unlock()
        }
    }

    // MARK: - Request handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: Self.queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            guard let request = String(data: data, encoding: .utf8) else {
                self.sendError(status: 400, reason: "Bad Request", on: connection)
                return
            }
            self.processRequest(request, on: connection)
        }
    }

    private func processRequest(_ request: String, on connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendError(status: 400, reason: "Bad Request", on: connection)
            return
        }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendError(status: 400, reason: "Bad Request", on: connection)
            return
        }
        let method = parts[0]
        guard method == "GET" || method == "HEAD" else {
            sendError(status: 405, reason: "Method Not Allowed", on: connection)
            return
        }
        let path = parts[1]
        guard path.hasPrefix("/stream/") else {
            sendError(status: 404, reason: "Not Found", on: connection)
            return
        }
        let objectID = String(path.dropFirst("/stream/".count))
        guard !objectID.isEmpty else {
            sendError(status: 404, reason: "Not Found", on: connection)
            return
        }

        var range: HTTPRange?
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("range:") {
                let value = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                range = HTTPRange.parse(value)
                break
            }
        }

        Task {
            await serve(objectID: objectID, method: method, range: range, on: connection)
        }
    }

    private func serve(objectID: String, method: String, range: HTTPRange?, on connection: NWConnection) async {
        guard let layout = try? await VideoStreamingEngine.shared.loadLayout(objectID: objectID),
              layout.fileSize > 0 else {
            sendError(status: 404, reason: "Not Found", on: connection)
            return
        }

        let total = layout.fileSize
        let start: Int64
        let end: Int64
        let isRange: Bool

        if let range {
            isRange = true
            switch range {
            case .from(let offset):
                start = min(max(0, offset), total - 1)
                end = total - 1
            case .suffix(let count):
                start = max(0, total - count)
                end = total - 1
            case .closed(let lower, let upper):
                start = min(max(0, lower), total - 1)
                end = min(max(0, upper), total - 1)
            }
            guard start <= end, start < total else {
                sendError(status: 416, reason: "Range Not Satisfiable",
                          extraHeaders: ["Content-Range": "bytes */\(total)"], on: connection)
                return
            }
        } else {
            isRange = false
            start = 0
            end = total - 1
        }

        let length = end - start + 1
        var headers: [String: String] = [
            "Accept-Ranges": "bytes",
            "Content-Type": layout.contentType,
            "Content-Length": "\(length)",
            "Cache-Control": "no-store",
        ]
        if isRange {
            headers["Content-Range"] = "bytes \(start)-\(end)/\(total)"
        }

        let status = isRange ? 206 : 200
        let reason = isRange ? "Partial Content" : "OK"

        guard method == "GET" else {
            // HEAD: headers only, then close.
            await send(headData(status: status, reason: reason, headers: headers), on: connection)
            connection.cancel()
            return
        }

        await send(headData(status: status, reason: reason, headers: headers), on: connection)
        guard connection.state == .ready else {
            connection.cancel()
            return
        }

        let fetcher = VideoStreamingEngine.shared.fetcher(for: objectID)
        let stream = VideoStreamingEngine.shared.plaintextSliceStream(
            objectID: objectID, start: start, length: length, layout: layout, fetcher: fetcher
        )
        do {
            for try await slice in stream {
                if connection.state != .ready { break }
                await send(slice, on: connection)
            }
        } catch {
            // Client went away or a slice failed mid-stream — just close.
        }
        connection.cancel()
    }

    // MARK: - Response helpers

    private func headData(status: Int, reason: String, headers: [String: String]) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        return head.data(using: .utf8) ?? Data()
    }

    private func sendError(
        status: Int,
        reason: String,
        extraHeaders: [String: String] = [:],
        on connection: NWConnection
    ) {
        var headers = extraHeaders
        headers["Content-Length"] = "0"
        let data = headData(status: status, reason: reason, headers: headers)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func send(_ data: Data, on connection: NWConnection) async {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }
}

// MARK: - Range parsing

private enum HTTPRange {
    /// bytes=N-  (from offset to end of file)
    case from(Int64)
    /// bytes=-N  (last N bytes)
    case suffix(Int64)
    /// bytes=A-B
    case closed(Int64, Int64)

    static func parse(_ value: String) -> HTTPRange? {
        let cleaned = value.trimmingCharacters(in: .whitespaces)
        guard cleaned.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = cleaned.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let n = Int64(parts[1]), n >= 0 else { return nil }
            return .suffix(n)
        }
        guard let lower = Int64(parts[0]), lower >= 0 else { return nil }
        if parts[1].isEmpty {
            return .from(lower)
        }
        guard let upper = Int64(parts[1]), upper >= lower else { return nil }
        return .closed(lower, upper)
    }
}
