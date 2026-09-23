import Foundation
import os.log

/// Resolves gray tracks from the direct pyncmd source, then built-in search
/// providers when pyncmd cannot serve the original NetEase song ID.
enum UnblockService {
    private static let log = Logger(subsystem: "im.missuo.kumone", category: "audio-source")
    private static let httpClient = AudioSourceClient.shared
    private static let fallbackProviders: [any AudioSourceProvider] = [
        KugouAudioSourceProvider(),
        KuwoAudioSourceProvider(),
    ]

    struct Resolution {
        let source: ResolvedAudioSource?
        let attemptedSources: Set<AudioSourceID>
    }

    static func resolve(
        _ track: Track,
        enabledSources: Set<AudioSourceID>,
        excluding attemptedSources: Set<AudioSourceID>
    ) async -> Resolution {
        var newlyAttemptedSources = Set<AudioSourceID>()
        if enabledSources.contains(.pyncmd), !attemptedSources.contains(.pyncmd) {
            newlyAttemptedSources.insert(.pyncmd)
            do {
                return Resolution(
                    source: try await pyncmd(track),
                    attemptedSources: newlyAttemptedSources
                )
            } catch {
                logFailure(source: .pyncmd, operation: "resolve", error: error)
            }
        }

        for provider in fallbackProviders where enabledSources.contains(provider.id)
            && !attemptedSources.contains(provider.id) {
            newlyAttemptedSources.insert(provider.id)
            do {
                if let resolved = try await provider.resolve(track: track) {
                    return Resolution(source: resolved, attemptedSources: newlyAttemptedSources)
                }
            } catch {
                logFailure(source: provider.id, operation: "resolve", error: error)
            }
        }
        return Resolution(source: nil, attemptedSources: newlyAttemptedSources)
    }

    private static func pyncmd(_ track: Track) async throws -> ResolvedAudioSource {
        let urlString = "https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=\(track.id)&br=320"
        let data = try await httpClient.data(
            from: urlString,
            source: .pyncmd,
            operation: "resolve"
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AudioSourceProviderError.invalidResponse
        }
        guard let bitrate = object["br"] as? Int, bitrate > 0 else {
            throw AudioSourceProviderError.missingBitrate
        }
        guard let urlValue = object["url"] as? String else {
            throw AudioSourceProviderError.missingStreamURL
        }
        guard let url = URL(string: urlValue.replacingOccurrences(of: "http://", with: "https://")) else {
            throw AudioSourceProviderError.invalidURL
        }
        return ResolvedAudioSource(id: .pyncmd, displayName: AudioSourceID.pyncmd.displayName, url: url)
    }

    private static func logFailure(source: AudioSourceID, operation: String, error: Error) {
        log.error(
            "source=\(source.rawValue, privacy: .public) operation=\(operation, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
    }
}
