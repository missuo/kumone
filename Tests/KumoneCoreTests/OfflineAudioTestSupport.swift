import CryptoKit
import Foundation
import Network
@testable import KumoneCore

struct OfflineAudioFixture {
    let data: Data
    let descriptor: OfflineAudioDescriptor

    init(_ format: OfflineAudioFormat = .mp3, scope: String = "test-account") throws {
        let url = Bundle.module.url(forResource: "offline", withExtension: format.rawValue, subdirectory: "Fixtures")!
        data = try Data(contentsOf: url)
        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        descriptor = OfflineAudioDescriptor(identity: .init(accountScope: scope, trackID: 1, source: "netease",
                                                            quality: "exhigh", format: format, contentMD5: md5),
                                             byteCount: Int64(data.count), duration: 3)
    }

    func resource(url: URL) -> OfflineAudioResource { .init(descriptor: descriptor, url: url) }
    func store() -> OfflineStore {
        OfflineStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("kumone-offline-test-\(UUID())"), minimumFreeBytes: 0)
    }
}

/// Real loopback HTTP keeps Foundation/AVFoundation networking in the test.
/// Responses can ignore Range or be delayed; no external account is involved.
final class AudioFixtureServer: @unchecked Sendable {
    enum Mode { case ranges, sequential, redirect, truncated, changedETag }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "kumone.offline.fixture")
    private let lock = NSLock()
    private var requestRanges: [String] = []
    private var connections: [NWConnection] = []
    private let fixture: OfflineAudioFixture
    private let mode: Mode
    private let delay: TimeInterval
    private var port: UInt16 = 0
    private var waitingForStart = true

    var url: URL { URL(string: "http://127.0.0.1:\(port)/audio.\(fixture.descriptor.identity.format.rawValue)")! }
    var ranges: [String] { lock.lock(); defer { lock.unlock() }; return requestRanges }

    init(fixture: OfflineAudioFixture, mode: Mode = .ranges, delay: TimeInterval = 0) async throws {
        self.fixture = fixture
        self.mode = mode
        self.delay = delay
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, accumulated: Data())
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, self.waitingForStart else { return }
                if case .ready = state {
                    self.waitingForStart = false
                    self.port = self.listener.port!.rawValue
                    continuation.resume()
                } else if case .failed(let error) = state {
                    self.waitingForStart = false
                    continuation.resume(throwing: error)
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async {
            self.listener.cancel()
            self.connections.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, done, error in
            guard let self, error == nil, let data else { connection.cancel(); return }
            let bytes = accumulated + data
            guard let request = String(data: bytes, encoding: .utf8), request.contains("\r\n\r\n") else {
                if !done { self.receive(connection, accumulated: bytes) } else { connection.cancel() }
                return
            }
            self.respond(connection, request: request)
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        if mode == .redirect, !request.hasPrefix("GET /target") {
            let response = "HTTP/1.1 302 Found\r\nLocation: /target\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let range = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range:") }?
            .components(separatedBy: "=").last ?? "0-\(fixture.data.count - 1)"
        lock.lock()
        requestRanges.append(range)
        let count = requestRanges.count
        lock.unlock()
        let bounds = range.split(separator: "-").compactMap { Int($0) }
        let useRange = mode != .sequential && bounds.count == 2
        let start = useRange ? bounds[0] : 0
        let end = useRange ? min(bounds[1], fixture.data.count - 1) : fixture.data.count - 1
        guard start >= 0, start <= end else { connection.cancel(); return }
        var body = fixture.data.subdata(in: start..<(end + 1))
        let length = body.count
        if mode == .truncated { body = body.prefix(body.count / 2) }
        let contentType: String
        switch fixture.descriptor.identity.format {
        case .mp3: contentType = "audio/mpeg"
        case .m4a: contentType = "audio/mp4"
        case .flac: contentType = "audio/flac"
        }
        let etag = mode == .changedETag && count > 1 ? "version-2" : "version-1"
        var header = "HTTP/1.1 \(useRange ? "206 Partial Content" : "200 OK")\r\nContent-Type: \(contentType)\r\nContent-Length: \(length)\r\nETag: \"\(etag)\"\r\nConnection: close\r\n"
        if useRange { header += "Content-Range: bytes \(start)-\(end)/\(fixture.data.count)\r\n" }
        header += "\r\n"
        let responseBody = body
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            if error == nil { self?.send(responseBody, offset: 0, connection: connection) }
        })
    }

    private func send(_ data: Data, offset: Int, connection: NWConnection) {
        guard offset < data.count else { connection.cancel(); return }
        let end = min(data.count, offset + 16_384)
        connection.send(content: data.subdata(in: offset..<end), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + self.delay) { self.send(data, offset: end, connection: connection) }
        })
    }
}
