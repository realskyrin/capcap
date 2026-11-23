import Foundation

enum UploadProviderKind: String, Codable, CaseIterable {
    case tencent
    case qiniu
    case aliyun
    case s3
    case r2
    case custom

    var displayName: String {
        switch self {
        case .tencent: return L10n.providerTencentCOS
        case .qiniu:   return L10n.providerQiniuKodo
        case .aliyun:  return L10n.providerAliyunOSS
        case .s3:      return "Amazon S3"
        case .r2:      return "Cloudflare R2"
        case .custom:  return L10n.providerCustomHTTP
        }
    }
}

struct ProviderConfig: Codable, Equatable {
    var kind: UploadProviderKind
    var fields: [String: String]

    func value(_ key: String) -> String {
        (fields[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func nonEmpty(_ key: String) -> String? {
        let v = value(key)
        return v.isEmpty ? nil : v
    }
}

enum UploadError: LocalizedError {
    case missingConfig
    case invalidConfig(String)
    case network(String)
    case server(Int, String)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return L10n.uploadErrMissingConfig
        case .invalidConfig(let m):
            return "\(L10n.uploadErrInvalidConfigPrefix) \(m)"
        case .network(let m):
            return "\(L10n.uploadErrNetworkPrefix) \(m)"
        case .server(let code, let m):
            return "\(L10n.uploadErrServerPrefix(code)) \(m)"
        case .unexpectedResponse(let m):
            return "\(L10n.uploadErrUnexpectedResponsePrefix) \(m)"
        }
    }
}

/// 实现分布在各 provider uploader 中，custom 负责通用 HTTP multipart 接口。
protocol UploaderProtocol: Sendable {
    static var kind: UploadProviderKind { get }
    /// Returns nil when the config is usable, otherwise a localized error message.
    static func validate(_ config: ProviderConfig) -> String?
    /// Kicks off an upload. Progress and completion fire on the main queue.
    static func upload(
        data: Data,
        fileName: String,
        contentType: String,
        config: ProviderConfig,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    )
}

enum Uploaders {
    static func provider(for kind: UploadProviderKind) -> UploaderProtocol.Type {
        switch kind {
        case .tencent: return TencentCOSUploader.self
        case .qiniu:   return QiniuUploader.self
        case .aliyun:  return AliyunOSSUploader.self
        case .s3:      return S3Uploader.self
        case .r2:      return R2Uploader.self
        case .custom:  return CustomHTTPUploader.self
        }
    }
}
