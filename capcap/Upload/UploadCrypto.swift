import Foundation
import CryptoKit

enum UploadCrypto {
    static func hmacSHA1(key: String, message: String) -> Data {
        let k = SymmetricKey(data: Data(key.utf8))
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(message.utf8), using: k)
        return Data(mac)
    }

    static func hmacSHA1(key: Data, message: Data) -> Data {
        let k = SymmetricKey(data: key)
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: message, using: k)
        return Data(mac)
    }

    static func sha1Hex(_ message: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(message.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Standard base64 (used by Aliyun OSS Authorization header).
    static func base64(_ data: Data) -> String {
        data.base64EncodedString()
    }

    /// URL-safe base64 with `+` -> `-`, `/` -> `_`, padding kept.
    static func base64URLSafe(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
}

extension String {
    /// Percent-encode for COS / OSS canonical request building. Encodes everything
    /// outside of the unreserved set (A-Z a-z 0-9 - _ . ~).
    func cosURLEncoded() -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
