import Foundation

enum UploadProviderKind: String, Codable, CaseIterable {
    case tencent
    case qiniu
    case aliyun

    var displayName: String {
        switch self {
        case .tencent: return L10n.lang == .zh ? "腾讯云 COS" : "Tencent COS"
        case .qiniu:   return L10n.lang == .zh ? "七牛云 Kodo" : "Qiniu Kodo"
        case .aliyun:  return L10n.lang == .zh ? "阿里云 OSS" : "Aliyun OSS"
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
            return L10n.lang == .zh ? "未配置上传图床" : "No uploader configured"
        case .invalidConfig(let m):
            return (L10n.lang == .zh ? "配置无效: " : "Invalid config: ") + m
        case .network(let m):
            return (L10n.lang == .zh ? "网络错误: " : "Network error: ") + m
        case .server(let code, let m):
            return (L10n.lang == .zh ? "上传失败 (\(code)): " : "Upload failed (\(code)): ") + m
        case .unexpectedResponse(let m):
            return (L10n.lang == .zh ? "响应异常: " : "Unexpected response: ") + m
        }
    }
}

/// Implementations live in TencentCOSUploader / QiniuUploader / AliyunOSSUploader.
protocol UploaderProtocol {
    static var kind: UploadProviderKind { get }
    /// Returns nil when the config is usable, otherwise a localized error message.
    static func validate(_ config: ProviderConfig) -> String?
    /// Kicks off an upload. Progress and completion fire on the main queue.
    static func upload(
        data: Data,
        fileName: String,
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
        }
    }
}
