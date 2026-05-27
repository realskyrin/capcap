import Foundation

enum TranslationError: LocalizedError {
    case missingAPIKey
    case badEndpoint
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return L10n.translationErrMissingAPIKey
        case .badEndpoint:
            return L10n.translationErrBadEndpoint
        case .badResponse:
            return L10n.translationErrBadResponse
        case let .http(code, body):
            let detail = body.isEmpty ? "" : " — \(body)"
            return "HTTP \(code)\(detail)"
        }
    }
}

/// Streams translations. OpenAI / DeepSeek / Custom share the OpenAI
/// chat-completions SSE format; Claude uses Anthropic Messages SSE; DeepL
/// returns a single JSON payload that is yielded as one chunk.
enum TranslationService {

    /// Yields translated text deltas as they arrive. Cancelling the consuming
    /// task cancels the underlying network request.
    static func stream(
        text: String,
        target: TranslationLanguage,
        kind: TranslationProviderKind,
        config: TranslationConfig
    ) -> AsyncThrowingStream<String, Error> {
        if !kind.isDeepL {
            return streamChat(
                text: text,
                system: systemPrompt(for: target),
                kind: kind,
                config: config
            )
        }

        return AsyncThrowingStream { continuation in
            let work = Task.detached(priority: .userInitiated) {
                do {
                    let translated = try await translateWithDeepL(text: text, target: target, config: config)
                    if !translated.isEmpty {
                        continuation.yield(translated)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Sends a tiny translation request to confirm the API key, endpoint and
    /// model actually work. Returns `nil` on success, or the failure reason.
    static func verify(
        kind: TranslationProviderKind,
        config: TranslationConfig
    ) async -> Error? {
        do {
            for try await _ in stream(text: "hello", target: .chinese, kind: kind, config: config) {
                return nil   // first delta arrived — credentials work
            }
            return nil       // finished without error
        } catch {
            return error
        }
    }

    static func fetchDictionaryEntry(
        word: String,
        target: TranslationLanguage,
        kind: TranslationProviderKind,
        config: TranslationConfig
    ) async throws -> DictionaryEntry {
        guard !kind.isDeepL else { throw TranslationError.badResponse }

        var raw = ""
        let prompt = dictionaryUserPrompt(word: word)
        for try await delta in streamChat(
            text: prompt,
            system: dictionarySystemPrompt(for: target),
            kind: kind,
            config: config
        ) {
            raw += delta
        }
        return parseDictionaryEntry(raw, fallbackWord: word)
    }

    // MARK: - Request building

    private static func systemPrompt(for target: TranslationLanguage) -> String {
        """
        You are a professional translation engine. Translate the text the user \
        provides into \(target.promptName). If the text is already written in \
        \(target.promptName), translate it into English instead. Output only the \
        final translation — no explanations, no notes, no quotation marks, no \
        language labels. Preserve the original line breaks.
        """
    }

    private static func dictionarySystemPrompt(for target: TranslationLanguage) -> String {
        """
        You are a concise bilingual dictionary engine. Return only valid JSON, \
        without Markdown fences, comments, or extra text. The JSON object must \
        contain string fields: word, phonetic, partOfSpeech, definition, \
        translation, example, exampleTranslation, difficulty. Explain definition in \
        \(target.promptName). Use IPA for phonetic, English lower-case for \
        partOfSpeech, translate the word into \(target.promptName) for translation, \
        one natural English sentence for example, translate that example into \
        \(target.promptName), and use a CEFR level like A1, A2, B1, B2, C1, \
        or C2 for difficulty when applicable.
        """
    }

    private static func dictionaryUserPrompt(word: String) -> String {
        "Word: \(word)"
    }

    private static func streamChat(
        text: String,
        system: String,
        kind: TranslationProviderKind,
        config: TranslationConfig
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task.detached(priority: .userInitiated) {
                do {
                    let request = try buildRequest(
                        text: text,
                        system: system,
                        kind: kind,
                        config: config
                    )
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw TranslationError.badResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 600 { break }
                        }
                        throw TranslationError.http(http.statusCode, body)
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty || payload == "[DONE]" { continue }
                        guard let data = payload.data(using: .utf8) else { continue }
                        if let delta = kind.isClaude
                            ? parseClaudeDelta(data)
                            : parseOpenAIDelta(data) {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private static func buildRequest(
        text: String,
        system: String,
        kind: TranslationProviderKind,
        config: TranslationConfig
    ) throws -> URLRequest {
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw TranslationError.missingAPIKey }
        guard let url = URL(string: config.resolvedEndpoint(for: kind)),
              url.scheme != nil else {
            throw TranslationError.badEndpoint
        }

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let model = config.resolvedModel(for: kind)
        let body: [String: Any]

        if kind.isClaude {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": model,
                "max_tokens": 4096,
                "temperature": 0.3,
                "stream": true,
                "system": system,
                "messages": [["role": "user", "content": text]],
            ]
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = [
                "model": model,
                "temperature": 0.3,
                "stream": true,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": text],
                ],
            ]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func parseDictionaryEntry(_ raw: String, fallbackWord: String) -> DictionaryEntry {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return DictionaryEntry(word: fallbackWord)
        }

        let json = extractJSONObject(from: trimmed) ?? trimmed
        if let data = json.data(using: .utf8),
           let entry = try? JSONDecoder().decode(DictionaryEntry.self, from: data) {
            return entry.normalized(fallbackWord: fallbackWord)
        }

        return DictionaryEntry(word: fallbackWord, definition: trimmed)
    }

    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        return String(text[start...end])
    }

    // MARK: - DeepL

    private struct DeepLTranslationResult {
        let text: String
        let detectedSourceLanguage: String?
    }

    private static let deepLProEndpoint = "https://api.deepl.com/v2/translate"
    private static let deepLFreeEndpoint = "https://api-free.deepl.com/v2/translate"

    private static func translateWithDeepL(
        text: String,
        target: TranslationLanguage,
        config: TranslationConfig
    ) async throws -> String {
        let result = try await requestDeepLTranslation(text: text, target: target, config: config)
        if target != .english,
           deepLSourceMatchesTarget(result.detectedSourceLanguage, target: target) {
            let fallback = try await requestDeepLTranslation(text: text, target: .english, config: config)
            return fallback.text
        }
        return result.text
    }

    private static func requestDeepLTranslation(
        text: String,
        target: TranslationLanguage,
        config: TranslationConfig
    ) async throws -> DeepLTranslationResult {
        let request = try buildDeepLRequest(text: text, target: target, config: config)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TranslationError.http(http.statusCode, String(body.prefix(600)))
        }
        return try parseDeepLResponse(data)
    }

    private static func buildDeepLRequest(
        text: String,
        target: TranslationLanguage,
        config: TranslationConfig
    ) throws -> URLRequest {
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw TranslationError.missingAPIKey }
        guard let url = URL(string: resolvedDeepLEndpoint(config: config, apiKey: apiKey)),
              url.scheme != nil else {
            throw TranslationError.badEndpoint
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

    private static func resolvedDeepLEndpoint(config: TranslationConfig, apiKey: String) -> String {
        let endpoint = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesFreeEndpoint = isDeepLFreeAPIKey(apiKey)
        guard !endpoint.isEmpty else {
            return usesFreeEndpoint ? deepLFreeEndpoint : deepLProEndpoint
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
        return components.url?.absoluteString ?? deepLFreeEndpoint
    }

    private static func isDeepLFreeAPIKey(_ apiKey: String) -> Bool {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasSuffix(":fx")
    }

    private static func parseDeepLResponse(_ data: Data) throws -> DeepLTranslationResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let translations = json["translations"] as? [[String: Any]],
              let first = translations.first,
              let text = first["text"] as? String else {
            throw TranslationError.badResponse
        }
        return DeepLTranslationResult(
            text: text,
            detectedSourceLanguage: first["detected_source_language"] as? String
        )
    }

    private static func deepLSourceMatchesTarget(
        _ sourceLanguage: String?,
        target: TranslationLanguage
    ) -> Bool {
        guard let sourceLanguage else { return false }
        return deepLBaseLanguage(sourceLanguage) == deepLBaseLanguage(target.deepLTargetCode)
    }

    private static func deepLBaseLanguage(_ code: String) -> String {
        code.uppercased().split(separator: "-").first.map(String.init) ?? code.uppercased()
    }

    // MARK: - SSE parsing

    /// OpenAI chunk: `{ "choices": [ { "delta": { "content": "…" } } ] }`
    private static func parseOpenAIDelta(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String,
              !content.isEmpty else {
            return nil
        }
        return content
    }

    /// Claude chunk: `{ "type": "content_block_delta", "delta": { "text": "…" } }`
    private static func parseClaudeDelta(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["type"] as? String) == "content_block_delta",
              let delta = json["delta"] as? [String: Any],
              let text = delta["text"] as? String,
              !text.isEmpty else {
            return nil
        }
        return text
    }
}
