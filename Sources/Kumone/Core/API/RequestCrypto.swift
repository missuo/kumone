import Foundation
import CommonCrypto
import CryptoKit

/// NetEase Cloud Music request encryption (eapi): AES-128-ECB over
/// "url + payload + md5 digest" with a fixed key, hex output.
enum NeteaseCrypto {
    private static let eapiKey = "e82ckenh8dichen8"

    /// Encrypts a JSON payload for an `/eapi/...` endpoint.
    /// - Parameter apiPath: the internal API path, e.g. "/api/song/enhance/player/url/v1"
    static func eapi(apiPath: String, payload: Data) -> [String: String] {
        let text = String(decoding: payload, as: UTF8.self)
        let message = "nobody\(apiPath)use\(text)md5forencrypt"
        let digest = Insecure.MD5.hash(data: Data(message.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let data = "\(apiPath)-36cd479b6b5-\(text)-36cd479b6b5-\(digest)"
        let encrypted = aes128(Data(data.utf8), key: eapiKey)
        return ["params": encrypted.map { String(format: "%02X", $0) }.joined()]
    }

    /// AES-128-ECB encryption with PKCS7 padding.
    private static func aes128(_ data: Data, key: String) -> Data {
        let keyData = Data(key.utf8)
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                keyData.withUnsafeBytes { keyPtr in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                            keyPtr.baseAddress, keyData.count, nil,
                            dataPtr.baseAddress, data.count,
                            outPtr.baseAddress, outPtr.count, &written)
                }
            }
        }
        precondition(status == kCCSuccess, "AES encryption failed: \(status)")
        return out.prefix(written)
    }
}
