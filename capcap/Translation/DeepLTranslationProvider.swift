import Foundation

enum DeepLTranslationProvider: DirectTranslationProvider {
    private static let proEndpoint = "https://api.deepl.com/v2/translate"
    private static let freeEndpoint = "https://api-free.deepl.com/v2/translate"

    static func translate(
        text: String,
        target: TranslationLanguage,
        config: TranslationConfig
    ) async throws -> String {
        let request = try buildRequest(text: text, target: target, config: config)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationServiceError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TranslationServiceError.http(http.statusCode, String(body.prefix(600)))
        }
        return try parseResponse(data)
    }

    private static func buildRequest(
        text: String,
        target: TranslationLanguage,
        config: TranslationConfig
    ) throws -> URLRequest {
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw TranslationServiceError.missingAPIKey }
        guard let url = URL(string: resolvedEndpoint(config: config, apiKey: apiKey)),
              url.scheme != nil else {
            throw TranslationServiceError.badEndpoint
        }

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "text": [text],
            "target_lang": target.deepLTargetCode,
            "preserve_formatting": true,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func resolvedEndpoint(config: TranslationConfig, apiKey: String) -> String {
        let endpoint = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesFreeEndpoint = isFreeAPIKey(apiKey)
        guard !endpoint.isEmpty else {
            return usesFreeEndpoint ? freeEndpoint : proEndpoint
        }
        guard var components = URLComponents(string: endpoint),
              let host = components.host?.lowercased(),
              host == "api.deepl.com" || host == "api-free.deepl.com" else {
            return endpoint
        }

        components.host = usesFreeEndpoint ? "api-free.deepl.com" : "api.deepl.com"
        if components.path.isEmpty || components.path == "/" {
            components.path = "/v2/translate"
        }
        return components.url?.absoluteString ?? freeEndpoint
    }

    private static func isFreeAPIKey(_ apiKey: String) -> Bool {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasSuffix(":fx")
    }

    private static func parseResponse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let translations = json["translations"] as? [[String: Any]],
              let first = translations.first,
              let text = first["text"] as? String else {
            throw TranslationServiceError.badResponse
        }
        return text
    }
}
