import Foundation

/// One coordinator owns one resource. All AVFoundation range consumers share
/// its transfer; OfflineStore rejects a second concurrent writer for that asset.
/// Download queues, background sessions and prefetch policies are later phases.
actor AudioTransferCoordinator {
    nonisolated let resource: OfflineAudioResource
    private let store: OfflineStore
    private let session: URLSession
    private let writer = UUID()
    private var started = false
    private var closed = false
    private var active: Task<Void, Error>?
    private var failure: Error?
    private var etag: String?
    private var progressVersion = 0
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private(set) var receivedByteCount: Int64 = 0

    init(resource: OfflineAudioResource, store: OfflineStore, session: URLSession = .shared) {
        self.resource = resource
        self.store = store
        self.session = session
    }

    /// Returns a contiguous available prefix, never sparse/unreceived bytes.
    func read(at offset: Int64, maximum: Int) async throws -> Data {
        try Task.checkCancellation()
        guard !closed, offset >= 0, offset < resource.descriptor.byteCount, maximum > 0 else {
            throw OfflineAudioError.unavailable
        }
        if !started {
            try await store.begin(resource.descriptor, writer: writer)
            started = true
        }
        let maximum = min(maximum, 256 * 1024, Int(resource.descriptor.byteCount - offset))
        while true {
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            let observedVersion = progressVersion
            if let data = try await store.read(id: resource.descriptor.identity.id, at: offset, maximum: maximum) { return data }
            if progressVersion != observedVersion { continue }
            if let failure { throw failure }
            // Check again after the actor hop; close or another request may
            // have changed ownership while the store was reading.
            guard !closed else { throw CancellationError() }
            if active == nil {
                let record = try await store.record(id: resource.descriptor.identity.id)
                if progressVersion != observedVersion || active != nil { continue }
                let nextReceivedOffset = record?.ranges.ranges.first(where: { $0.lowerBound > offset })?.lowerBound
                    ?? resource.descriptor.byteCount
                let end = min(nextReceivedOffset, offset + 256 * 1024)
                active = Task { try await self.fetch(offset..<end) }
            }
            try await waitForProgress()
        }
    }

    func download() async throws {
        var offset: Int64 = 0
        while offset < resource.descriptor.byteCount {
            offset += Int64(try await read(at: offset, maximum: 256 * 1024).count)
        }
        if let active { try await active.value }
        if let failure { throw failure }
        try await store.finalize(id: resource.descriptor.identity.id, writer: writer)
    }

    func close() async {
        closed = true
        let task = active
        task?.cancel()
        wakeWaiters(error: CancellationError())
        // Release ownership only after the old task has stopped writing.
        _ = try? await task?.value
        await store.releaseWriter(id: resource.descriptor.identity.id, writer: writer)
    }

    private func fetch(_ range: Range<Int64>) async throws {
        do {
            var request = URLRequest(url: resource.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if let etag { request.setValue(etag, forHTTPHeaderField: "If-Range") }
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw OfflineAudioError.invalidResponse }
            let info = try AudioHTTPResponse(response: http, requested: range, descriptor: resource.descriptor, previousETag: etag)
            etag = info.etag
            var offset = info.offset
            var buffer = Data()
            buffer.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                try Task.checkCancellation()
                guard offset + Int64(buffer.count) < info.offset + info.length else { throw OfflineAudioError.invalidResponse }
                buffer.append(byte)
                if buffer.count == 64 * 1024 {
                    try await append(buffer, at: offset)
                    offset += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try await append(buffer, at: offset)
                offset += Int64(buffer.count)
            }
            guard offset == info.offset + info.length else { throw OfflineAudioError.incomplete }
            if let record = try await store.record(id: resource.descriptor.identity.id), record.ranges.covers(record.descriptor.byteCount) {
                try await store.finalize(id: record.id, writer: writer)
            }
            active = nil
            wakeWaiters()
        } catch {
            failure = error
            active = nil
            wakeWaiters(error: error)
            throw error
        }
    }

    private func append(_ data: Data, at offset: Int64) async throws {
        try Task.checkCancellation()
        try await store.write(data, at: offset, id: resource.descriptor.identity.id, writer: writer)
        receivedByteCount += Int64(data.count)
        wakeWaiters()
    }

    private func waitForProgress() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled || closed { continuation.resume(throwing: CancellationError()) }
                else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func wakeWaiters(error: Error? = nil) {
        progressVersion += 1
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
    }
}
