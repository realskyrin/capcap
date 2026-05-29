import Foundation

enum DeepLXTranslationProvider: DirectTranslationProvider {
    private struct TranslationResult {
        let text: String
        let detectedSourceLanguage: String?
    }

    static func translate(
        text: String,
        target: TranslationLanguage,
        config: TranslationConfig
    ) async throws -> String {
        let result = try await requestTranslation(text: text, target: target, config: config)
        if target != .english,
           sourceMatchesTarget(result.detectedSourceLanguage, target: target) {
            let fallback = try await requestTranslation(text: text, target: .english, config: config)
            return fallback.text
        }
        return result.text
    }

    private static func requestTranslation(
        text: String,
        target: TranslationLanguage,
        config: TranslationConfig
    ) async throws -> TranslationResult {
        let request = try buildRequest(text: text, target: target, config: config)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TranslationError.http(http.statusCode, String(body.prefix(600)))
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
            throw TranslationError.missingAPIKey
        }
        guard let url = URL(string: resolvedEndpoint(endpoint: endpoint, apiKey: apiKey)),
              url.scheme != nil else {
            throw TranslationError.badEndpoint
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

    private static func parseResponse(_ data: Data) throws -> TranslationResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationError.badResponse
        }

        if let code = json["code"] as? Int, code != 200 {
            let message = json["message"] as? String ?? json["msg"] as? String ?? ""
            throw TranslationError.http(code, message)
        }

        if let text = json["data"] as? String {
            return TranslationResult(
                text: text,
                detectedSourceLanguage: detectedSourceLanguage(from: json)
            )
        }

        if let data = json["data"] as? [String: Any],
           let text = data["text"] as? String ?? data["translation"] as? String {
            return TranslationResult(
                text: text,
                detectedSourceLanguage: detectedSourceLanguage(from: data) ?? detectedSourceLanguage(from: json)
            )
        }

        throw TranslationError.badResponse
    }

    private static func detectedSourceLanguage(from json: [String: Any]) -> String? {
        json["source_lang"] as? String
            ?? json["sourceLang"] as? String
            ?? json["detected_source_language"] as? String
    }

    private static func sourceMatchesTarget(
        _ sourceLanguage: String?,
        target: TranslationLanguage
    ) -> Bool {
        guard let sourceLanguage else { return false }
        return baseLanguage(sourceLanguage) == baseLanguage(targetCode(for: target))
    }

    private static func baseLanguage(_ code: String) -> String {
        code.uppercased().split(separator: "-").first.map(String.init) ?? code.uppercased()
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
