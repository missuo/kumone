import AVFoundation
import Foundation

/// Keep this owner alive for the lifetime of its AVURLAsset: AVFoundation's
/// resource-loader delegate reference is weak. Delegate state stays on `queue`.
final class CachingAssetResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let asset: AVURLAsset
    private let transfer: AudioTransferCoordinator
    private let queue = DispatchQueue(label: "im.missuo.Kumone.audio-resource-loader")
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var closed = false
    private let onFailure: @Sendable () -> Void
    private var reportedFailure = false

    init(transfer: AudioTransferCoordinator, onFailure: @escaping @Sendable () -> Void = {}) {
        self.transfer = transfer
        self.onFailure = onFailure
        let identity = transfer.resource.descriptor.identity
        // The identity is a hex digest, so URL construction cannot incorporate
        // arbitrary server paths or account text.
        asset = AVURLAsset(url: URL(string: "kumone-audio://asset/\(identity.id).\(identity.format.rawValue)")!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard request.request.url?.scheme == "kumone-audio" else { return false }
        guard !closed else { request.finishLoading(with: CancellationError()); return true }
        let descriptor = transfer.resource.descriptor
        if let info = request.contentInformationRequest {
            info.contentType = descriptor.identity.format.contentType
            info.contentLength = descriptor.byteCount
            // The coordinator can satisfy arbitrary ranges even when the CDN
            // requires sequential transfer of the whole representation.
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = request.dataRequest else { request.finishLoading(); return true }
        let offset = max(dataRequest.requestedOffset, dataRequest.currentOffset)
        guard offset >= 0, offset <= descriptor.byteCount, dataRequest.requestedLength >= 0 else {
            request.finishLoading(with: OfflineAudioError.invalidResponse)
            return true
        }
        let end: Int64
        if dataRequest.requestsAllDataToEndOfResource { end = descriptor.byteCount }
        else {
            let (requestedEnd, overflow) = dataRequest.requestedOffset.addingReportingOverflow(Int64(dataRequest.requestedLength))
            guard !overflow, requestedEnd >= offset else {
                request.finishLoading(with: OfflineAudioError.invalidResponse)
                return true
            }
            end = min(descriptor.byteCount, requestedEnd)
        }
        let key = ObjectIdentifier(request)
        requests[key] = Task { [weak self, transfer] in
            do {
                var cursor = offset
                while cursor < end {
                    try Task.checkCancellation()
                    do {
                        let data = try await transfer.read(at: cursor, maximum: Int(min(end - cursor, 256 * 1024)))
                        guard let self, await self.deliver(data, to: request) else { return }
                        cursor += Int64(data.count)
                    } catch {
                        guard AudioTransferCoordinator.isConnectivityFailure(error) else { throw error }
                        // Keep AVFoundation's request and buffered audio alive.
                        // Seeking or switching tracks cancels this retry as usual.
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                self?.finish(request, error: nil)
            } catch { self?.finish(request, error: error) }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        requests.removeValue(forKey: ObjectIdentifier(request))?.cancel()
    }

    func close(closeTransfer: Bool = true) async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.closed = true
                for task in self.requests.values { task.cancel() }
                self.requests.removeAll()
                continuation.resume()
            }
        }
        asset.cancelLoading()
        if closeTransfer { await transfer.close() }
    }

    private func deliver(_ data: Data, to request: AVAssetResourceLoadingRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.requests[ObjectIdentifier(request)] != nil, !request.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                request.dataRequest?.respond(with: data)
                continuation.resume(returning: true)
            }
        }
    }

    private func finish(_ request: AVAssetResourceLoadingRequest, error: Error?) {
        queue.async {
            guard self.requests.removeValue(forKey: ObjectIdentifier(request)) != nil, !request.isCancelled else { return }
            if let error {
                request.finishLoading(with: error)
                if !self.closed, !self.reportedFailure, !(error is CancellationError) {
                    self.reportedFailure = true
                    self.onFailure()
                }
            } else { request.finishLoading() }
        }
    }
}
