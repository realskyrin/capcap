import Foundation

/// 通用 HTTP multipart 图传。
///
/// 必填字段只有 endpoint；其余字段用于适配常见的自建图床接口：
/// - fileField：multipart 文件字段名，默认 file
/// - headers：每行一个 Header: Value，可放 Authorization 等鉴权信息
/// - responsePath：成功响应中的 URL 路径，如 data.links.url
enum CustomHTTPUploader: UploaderProtocol {
    static let kind: UploadProviderKind = .custom

    static func validate(_ config: ProviderConfig) -> String? {
        guard let endpoint = config.nonEmpty("endpoint"),
              let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              scheme == "https" || (scheme == "http" && isLocalHost(host)) else {
            return L10n.uploadCustomInvalidEndpoint
        }

        let fileField = config.nonEmpty("fileField") ?? "file"
        if fileField.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\"" }) {
            return L10n.uploadCustomInvalidFileField
        }
        if parseHeaders(config.nonEmpty("headers")) == nil {
            return L10n.uploadCustomInvalidHeader
        }
        return nil
    }

    static func upload(
        data: Data,
        fileName: String,
        contentType: String,
        config: ProviderConfig,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        if let err = validate(config) {
            completion(.failure(UploadError.invalidConfig(err)))
            return
        }
        guard let endpoint = config.nonEmpty("endpoint"), let url = URL(string: endpoint) else {
            completion(.failure(UploadError.invalidConfig(L10n.uploadCustomInvalidEndpoint)))
            return
        }

        let boundary = "----capcap-\(UUID().uuidString)"
        let fileField = config.nonEmpty("fileField") ?? "file"
        let body = multipartBody(
            data: data,
            fileName: fileName,
            contentType: contentType,
            fieldName: fileField,
            boundary: boundary
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        applyHeaders(config.nonEmpty("headers"), to: &request)

        let client = UploadHTTPClient()
        client.upload(request: request, body: body, progress: progress) { result in
            withExtendedLifetime(client) {
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let (responseData, response)):
                    guard (200..<300).contains(response.statusCode) else {
                        let message = String(data: responseData, encoding: .utf8)
                            ?? "HTTP \(response.statusCode)"
                        completion(.failure(UploadError.server(response.statusCode, message)))
                        return
                    }
                    guard let publicURL = responseURL(
                        from: responseData,
                        path: config.nonEmpty("responsePath")
                    ) else {
                        completion(.failure(UploadError.unexpectedResponse(
                            L10n.uploadCustomResponseURLMissing
                        )))
                        return
                    }
                    completion(.success(publicURL))
                }
            }
        }
    }

    /// 解析 JSON 路径并兼容纯文本 URL，便于接入简单自建接口。
    static func responseURL(from data: Data, path: String?) -> URL? {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty,
           let value = value(in: object, path: path),
           let url = validURL(from: value) {
            return url
        }

        if let object = try? JSONSerialization.jsonObject(with: data) {
            for candidate in ["url", "data.url", "data.links.url", "link", "data.link"] {
                if let value = value(in: object, path: candidate),
                   let url = validURL(from: value) {
                    return url
                }
            }
            if let url = validURL(from: object) {
                return url
            }
        }

        return validURL(from: String(data: data, encoding: .utf8) ?? "")
    }

    private static func multipartBody(
        data: Data,
        fileName: String,
        contentType: String,
        fieldName: String,
        boundary: String
    ) -> Data {
        var body = Data()
        let safeFileName = fileName.replacingOccurrences(of: "\"", with: "'")
        func append(_ string: String) {
            body.append(Data(string.utf8))
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(safeFileName)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func parseHeaders(_ raw: String?) -> [String: String]? {
        guard let raw else { return [:] }
        var headers: [String: String] = [:]
        for line in raw.split(whereSeparator: \.isNewline) {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            guard let separator = text.firstIndex(of: ":") else { return nil }
            let name = String(text[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(text[text.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.contains("\r"), !value.contains("\n") else { return nil }
            headers[name] = value
        }
        return headers
    }

    private static func applyHeaders(_ raw: String?, to request: inout URLRequest) {
        guard let headers = parseHeaders(raw) else { return }
        for (name, value) in headers {
            // 保留 multipart 必需头，避免用户配置覆盖边界和真实长度。
            let lowercased = name.lowercased()
            guard lowercased != "content-type",
                  lowercased != "content-length",
                  lowercased != "host" else { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private static func value(in object: Any, path: String) -> Any? {
        var current: Any = object
        for key in path.split(separator: ".") {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[String(key)] else { return nil }
            current = next
        }
        return current
    }

    private static func validURL(from value: Any) -> URL? {
        let string: String?
        if let value = value as? String {
            string = value.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            string = nil
        }
        guard let string, let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
    }
}
