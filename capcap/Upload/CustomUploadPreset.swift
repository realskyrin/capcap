import Foundation

/// 预设只负责生成接口规则，站点和凭据分开保存，切换图床时不会覆盖原配置。
enum CustomUploadPreset: String, CaseIterable {
    case zipline
    case easyImages
    case other

    static func selected(in config: ProviderConfig) -> Self {
        // 老版本只保存通用字段，没有 preset 时继续按原接口上传。
        Self(rawValue: config.value("preset")) ?? .other
    }

    var displayName: String {
        switch self {
        case .zipline: return "Zipline"
        case .easyImages: return L10n.uploadPresetEasyImages
        case .other: return L10n.uploadPresetOther
        }
    }

    var siteKey: String {
        switch self {
        case .zipline: return "ziplineURL"
        case .easyImages: return "easyImagesURL"
        case .other: return "endpoint"
        }
    }

    var tokenKey: String? {
        switch self {
        case .zipline: return "ziplineToken"
        case .easyImages: return "easyImagesToken"
        case .other: return nil
        }
    }

    func resolvedConfig(from config: ProviderConfig) -> ProviderConfig {
        let token = tokenKey.map { config.value($0) } ?? ""
        switch self {
        case .zipline:
            return ProviderConfig(kind: .custom, fields: [
                "endpoint": endpoint(for: config.value(siteKey), apiPath: "api/upload"),
                "fileField": "file",
                // 单文件纯文本响应可直接取得图片地址，无需解析数组。
                "headers": "Authorization: \(token)\nx-zipline-no-json: true",
            ])
        case .easyImages:
            return ProviderConfig(kind: .custom, fields: [
                "endpoint": endpoint(for: config.value(siteKey), apiPath: "api/index.php"),
                "fileField": "image",
                "formFields": "token=\(token)",
                "responsePath": "url",
            ])
        case .other:
            return config
        }
    }

    private func endpoint(for site: String, apiPath: String) -> String {
        guard !site.isEmpty, var components = URLComponents(string: site),
              components.host != nil else { return site }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        // 接受站点根地址、子目录和完整接口地址，避免重复追加接口路径。
        if !path.hasSuffix("/\(apiPath)") { path += "/\(apiPath)" }
        components.percentEncodedPath = path
        return components.url?.absoluteString ?? site
    }
}
