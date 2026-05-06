import Foundation

/// Tencent Cloud COS V5 PUT Object uploader.
/// Required fields:
///   secretId, secretKey, bucket (must include APPID suffix), region, [path], [customUrl]
enum TencentCOSUploader: UploaderProtocol {
    static let kind: UploadProviderKind = .tencent

    static func validate(_ config: ProviderConfig) -> String? {
        let zh = L10n.lang == .zh
        for key in ["secretId", "secretKey", "bucket", "region"] {
            if config.nonEmpty(key) == nil {
                return zh ? "缺少 \(key)" : "Missing \(key)"
            }
        }
        return nil
    }

    static func upload(
        data: Data,
        fileName: String,
        config: ProviderConfig,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        if let err = validate(config) {
            completion(.failure(UploadError.invalidConfig(err)))
            return
        }
        let secretId  = config.value("secretId")
        let secretKey = config.value("secretKey")
        let bucket    = config.value("bucket")
        let region    = config.value("region")
        let path      = normalizedPath(config.nonEmpty("path"))
        let key       = path + fileName

        let host = "\(bucket).cos.\(region).myqcloud.com"
        guard let url = URL(string: "https://\(host)/\(encodedKey(key))") else {
            completion(.failure(UploadError.invalidConfig("bad bucket or region")))
            return
        }

        let now = Int(Date().timeIntervalSince1970)
        let keyTime = "\(now);\(now + 3600)"
        let signKey = UploadCrypto.hex(UploadCrypto.hmacSHA1(key: secretKey, message: keyTime))

        // Use empty header / param lists — sign just the method + URI.
        let httpURI = "/" + key.cosURLEncoded().replacingOccurrences(of: "%2F", with: "/")
        let httpString = "put\n\(httpURI)\n\n\n"
        let stringToSign = "sha1\n\(keyTime)\n\(UploadCrypto.sha1Hex(httpString))\n"
        let signature = UploadCrypto.hex(UploadCrypto.hmacSHA1(key: signKey, message: stringToSign))

        let auth = "q-sign-algorithm=sha1"
            + "&q-ak=\(secretId)"
            + "&q-sign-time=\(keyTime)"
            + "&q-key-time=\(keyTime)"
            + "&q-header-list="
            + "&q-url-param-list="
            + "&q-signature=\(signature)"

        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue("image/png", forHTTPHeaderField: "Content-Type")
        req.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        req.setValue(host, forHTTPHeaderField: "Host")

        let client = UploadHTTPClient()
        client.upload(request: req, body: data, progress: progress) { result in
            withExtendedLifetime(client) {
                switch result {
                case .failure(let err):
                    completion(.failure(err))
                case .success(let (body, response)):
                    if (200..<300).contains(response.statusCode) {
                        let final = finalURL(custom: config.nonEmpty("customUrl"), defaultHost: host, key: key)
                        completion(.success(final))
                    } else {
                        let msg = String(data: body, encoding: .utf8) ?? "HTTP \(response.statusCode)"
                        completion(.failure(UploadError.server(response.statusCode, msg)))
                    }
                }
            }
        }
    }

    private static func encodedKey(_ key: String) -> String {
        // Encode segment-by-segment so the slashes survive.
        key.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).cosURLEncoded() }
            .joined(separator: "/")
    }
}

/// Trim leading slashes, ensure trailing slash for non-empty values.
fileprivate func normalizedPath(_ raw: String?) -> String {
    guard var p = raw, !p.isEmpty else { return "" }
    while p.hasPrefix("/") { p.removeFirst() }
    while p.hasSuffix("/") { p.removeLast() }
    return p.isEmpty ? "" : p + "/"
}

/// Build the public URL the user gets in their clipboard.
fileprivate func finalURL(custom: String?, defaultHost: String, key: String) -> URL {
    let safeKey = key.split(separator: "/", omittingEmptySubsequences: false)
        .map { String($0).cosURLEncoded() }
        .joined(separator: "/")
    if let custom {
        let trimmed = custom.hasSuffix("/") ? String(custom.dropLast()) : custom
        return URL(string: "\(trimmed)/\(safeKey)") ?? URL(string: "https://\(defaultHost)/\(safeKey)")!
    }
    return URL(string: "https://\(defaultHost)/\(safeKey)")!
}
