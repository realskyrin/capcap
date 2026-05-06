import Foundation

/// Aliyun OSS PUT Object uploader (signature V1).
/// Required fields:
///   accessKeyId, accessKeySecret, bucket, area, [path], [customUrl]
/// `area` is the OSS endpoint without scheme (e.g. `oss-cn-hangzhou` or
/// `oss-cn-hangzhou.aliyuncs.com`).
enum AliyunOSSUploader: UploaderProtocol {
    static let kind: UploadProviderKind = .aliyun

    static func validate(_ config: ProviderConfig) -> String? {
        let zh = L10n.lang == .zh
        for key in ["accessKeyId", "accessKeySecret", "bucket", "area"] {
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
        let id      = config.value("accessKeyId")
        let secret  = config.value("accessKeySecret")
        let bucket  = config.value("bucket")
        let area    = AliyunPath.normalizeArea(config.value("area"))
        let path    = AliyunPath.normalizePath(config.nonEmpty("path"))
        let key     = path + fileName

        let host = "\(bucket).\(area)"
        guard let url = URL(string: "https://\(host)/\(AliyunPath.encode(key: key))") else {
            completion(.failure(UploadError.invalidConfig("bad bucket or area")))
            return
        }

        let date = AliyunPath.gmtDate()
        let contentType = "image/png"
        let resource = "/\(bucket)/\(key)"
        let stringToSign = "PUT\n\n\(contentType)\n\(date)\n\(resource)"
        let signature = UploadCrypto.base64(
            UploadCrypto.hmacSHA1(key: Data(secret.utf8), message: Data(stringToSign.utf8))
        )

        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(date, forHTTPHeaderField: "Date")
        req.setValue("OSS \(id):\(signature)", forHTTPHeaderField: "Authorization")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
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
                        let final = AliyunPath.finalURL(custom: config.nonEmpty("customUrl"),
                                                        defaultHost: host,
                                                        key: key)
                        completion(.success(final))
                    } else {
                        let msg = String(data: body, encoding: .utf8) ?? "HTTP \(response.statusCode)"
                        completion(.failure(UploadError.server(response.statusCode, msg)))
                    }
                }
            }
        }
    }
}

fileprivate enum AliyunPath {
    static func normalizeArea(_ raw: String) -> String {
        var a = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.hasPrefix("http://")  { a.removeFirst(7) }
        if a.hasPrefix("https://") { a.removeFirst(8) }
        while a.hasSuffix("/") { a.removeLast() }
        if !a.contains(".") { a += ".aliyuncs.com" }
        return a
    }

    static func normalizePath(_ raw: String?) -> String {
        guard var p = raw, !p.isEmpty else { return "" }
        while p.hasPrefix("/") { p.removeFirst() }
        while p.hasSuffix("/") { p.removeLast() }
        return p.isEmpty ? "" : p + "/"
    }

    static func encode(key: String) -> String {
        key.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).cosURLEncoded() }
            .joined(separator: "/")
    }

    static func gmtDate() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: Date())
    }

    static func finalURL(custom: String?, defaultHost: String, key: String) -> URL {
        let safeKey = encode(key: key)
        if let custom {
            let trimmed = custom.hasSuffix("/") ? String(custom.dropLast()) : custom
            return URL(string: "\(trimmed)/\(safeKey)") ?? URL(string: "https://\(defaultHost)/\(safeKey)")!
        }
        return URL(string: "https://\(defaultHost)/\(safeKey)")!
    }
}
