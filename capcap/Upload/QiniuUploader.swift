import Foundation

/// Qiniu Kodo uploader (multipart form-data with PutPolicy upload token).
/// Required fields:
///   accessKey, secretKey, bucket, domain, [region], [path]
/// `domain` is the public download host (e.g. `cdn.example.com`, no scheme).
/// `region` is one of z0/z1/z2/na0/as0/cn-east-2 (defaults to z0).
enum QiniuUploader: UploaderProtocol {
    static let kind: UploadProviderKind = .qiniu

    static func validate(_ config: ProviderConfig) -> String? {
        let zh = L10n.lang == .zh
        for key in ["accessKey", "secretKey", "bucket", "domain"] {
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
        let accessKey = config.value("accessKey")
        let secretKey = config.value("secretKey")
        let bucket    = config.value("bucket")
        let domain    = config.value("domain")
        let region    = config.nonEmpty("region") ?? "z0"
        let path      = QiniuPath.normalize(config.nonEmpty("path"))
        let key       = path + fileName

        // Build PutPolicy → upload token
        let deadline = Int(Date().timeIntervalSince1970) + 3600
        let putPolicy = "{\"scope\":\"\(bucket):\(key)\",\"deadline\":\(deadline)}"
        guard let policyData = putPolicy.data(using: .utf8) else {
            completion(.failure(UploadError.invalidConfig("policy encode")))
            return
        }
        let encodedPolicy = UploadCrypto.base64URLSafe(policyData)
        let sign = UploadCrypto.base64URLSafe(
            UploadCrypto.hmacSHA1(key: Data(secretKey.utf8), message: Data(encodedPolicy.utf8))
        )
        let token = "\(accessKey):\(sign):\(encodedPolicy)"

        guard let host = QiniuPath.uploadHost(for: region),
              let url = URL(string: host) else {
            completion(.failure(UploadError.invalidConfig("unknown region: \(region)")))
            return
        }

        // multipart/form-data
        let boundary = "----capcap-\(UUID().uuidString)"
        var body = Data()
        func addField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        addField("key", key)
        addField("token", token)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/png\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")

        let client = UploadHTTPClient()
        client.upload(request: req, body: body, progress: progress) { result in
            withExtendedLifetime(client) {
                switch result {
                case .failure(let err):
                    completion(.failure(err))
                case .success(let (respData, response)):
                    if (200..<300).contains(response.statusCode) {
                        var returnedKey = key
                        if let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                           let k = json["key"] as? String {
                            returnedKey = k
                        }
                        let final = QiniuPath.publicURL(domain: domain, key: returnedKey)
                        completion(.success(final))
                    } else {
                        let msg = String(data: respData, encoding: .utf8) ?? "HTTP \(response.statusCode)"
                        completion(.failure(UploadError.server(response.statusCode, msg)))
                    }
                }
            }
        }
    }
}

fileprivate enum QiniuPath {
    static func normalize(_ raw: String?) -> String {
        guard var p = raw, !p.isEmpty else { return "" }
        while p.hasPrefix("/") { p.removeFirst() }
        while p.hasSuffix("/") { p.removeLast() }
        return p.isEmpty ? "" : p + "/"
    }

    /// PicGo defaults to the global accelerated upload host (`upload.qiniup.com`)
    /// but offering region-specific hosts avoids cross-region 301s.
    static func uploadHost(for region: String) -> String? {
        switch region.lowercased() {
        case "z0", "huadong":           return "https://upload.qiniup.com"
        case "z1", "huabei":            return "https://upload-z1.qiniup.com"
        case "z2", "huanan":            return "https://upload-z2.qiniup.com"
        case "na0", "beimei":           return "https://upload-na0.qiniup.com"
        case "as0", "dongnanya":        return "https://upload-as0.qiniup.com"
        case "cn-east-2", "huadong-2":  return "https://upload-cn-east-2.qiniup.com"
        default: return "https://upload.qiniup.com"
        }
    }

    static func publicURL(domain: String, key: String) -> URL {
        let scheme: String
        let host: String
        if domain.hasPrefix("http://") {
            scheme = "http://"; host = String(domain.dropFirst(7))
        } else if domain.hasPrefix("https://") {
            scheme = "https://"; host = String(domain.dropFirst(8))
        } else {
            scheme = "https://"; host = domain
        }
        let trimmedHost = host.hasSuffix("/") ? String(host.dropLast()) : host
        let safeKey = key.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).cosURLEncoded() }
            .joined(separator: "/")
        return URL(string: "\(scheme)\(trimmedHost)/\(safeKey)")
            ?? URL(string: "\(scheme)\(trimmedHost)")!
    }
}
