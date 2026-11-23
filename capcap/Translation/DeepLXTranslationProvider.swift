import Foundation

enum DeepLXTranslationProvider: DirectTranslationProvider {
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
        let endpoint = config.resolvedEndpoint(for: .deeplx)
        guard !endpoint.contains("{{apiKey}}") || !apiKey.isEmpty else {
            throw TranslationServiceError.missingAPIKey
        }
        guard let url = URL(string: resolvedEndpoint(endpoint: endpoint, apiKey: apiKey)),
              url.scheme != nil else {
            throw TranslationServiceError.badEndpoint
        }

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty, !endpoint.contains("{{apiKey}}") {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "text": text,
            "source_lang": "auto",
            "target_lang": targetCode(for: target),
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func resolvedEndpoint(endpoint: String, apiKey: String) -> String {
        let encodedKey = apiKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? apiKey
        return endpoint.replacingOccurrences(of: "{{apiKey}}", with: encodedKey)
    }

    private static func parseResponse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationServiceError.badResponse
        }

        if let code = json["code"] as? Int, code != 200 {
            let message = json["message"] as? String ?? json["msg"] as? String ?? ""
            throw TranslationServiceError.http(code, message)
        }

        if let text = json["data"] as? String {
            return text
        }

        if let data = json["data"] as? [String: Any],
           let text = data["text"] as? String ?? data["translation"] as? String {
            return text
        }

        throw TranslationServiceError.badResponse
    }

    private static func targetCode(for target: TranslationLanguage) -> String {
        switch target {
        case .chinese:    return "ZH"
        case .english:    return "EN"
        case .vietnamese: return "VI"
        case .hindi:      return "HI"
        case .spanish:    return "ES"
        case .french:     return "FR"
        case .arabic:     return "AR"
        case .bengali:    return "BN"
        case .portuguese: return "PT"
        case .russian:    return "RU"
        case .urdu:       return "UR"
        case .indonesian: return "ID"
        case .german:     return "DE"
        case .japanese:   return "JA"
        case .korean:     return "KO"
        case .turkish:    return "TR"
        }
    }
}
