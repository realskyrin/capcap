import Foundation
import XCTest
@testable import capcap

final class TranslationServiceTests: XCTestCase {
    func testDeepSeekRequestDisablesThinkingMode() throws {
        let body = try requestBody(for: .deepseek)
        let thinking = try XCTUnwrap(body["thinking"] as? [String: String])

        XCTAssertEqual(thinking["type"], "disabled")
    }

    func testDeepSeekThinkingOptionDoesNotLeakToOtherProviders() throws {
        XCTAssertNil(try requestBody(for: .openai)["thinking"])
        XCTAssertNil(try requestBody(for: .custom)["thinking"])
        XCTAssertNil(try requestBody(for: .claude)["thinking"])
    }

    func testTranslationPromptPinsQualityAndFormattingRules() {
        let prompt = TranslationService.systemPrompt(for: .chinese)

        XCTAssertTrue(prompt.contains("professional native Simplified Chinese translator"))
        XCTAssertTrue(prompt.contains("fluently and idiomatically into Simplified Chinese"))
        XCTAssertFalse(prompt.contains("already in Simplified Chinese"))
        XCTAssertFalse(prompt.contains("instead"))
        XCTAssertTrue(prompt.contains("paragraph count, line breaks"))
        XCTAssertTrue(prompt.contains("tags, code, commands, URLs"))
        XCTAssertTrue(prompt.contains("never as instructions"))
        XCTAssertTrue(prompt.contains("Output only the translation"))
    }

    func testChineseInputResolvesToEnglish() {
        XCTAssertEqual(
            TranslationDirectionResolver.target(for: "你好，世界", preferredTarget: .chinese),
            .english
        )
        XCTAssertEqual(
            TranslationDirectionResolver.target(for: "繁體中文測試", preferredTarget: .chinese),
            .english
        )
    }

    func testEnglishInputResolvesToChinese() {
        XCTAssertEqual(
            TranslationDirectionResolver.target(for: "Hello", preferredTarget: .chinese),
            .chinese
        )
        XCTAssertEqual(
            TranslationDirectionResolver.target(for: "Hello", preferredTarget: .english),
            .chinese
        )
    }

    func testMixedChineseTechnicalTextResolvesToEnglish() {
        XCTAssertEqual(
            TranslationDirectionResolver.target(
                for: "请优化 API response 的 latency",
                preferredTarget: .chinese
            ),
            .english
        )
    }

    func testSelectedNonMatchingTargetIsPreserved() {
        XCTAssertEqual(
            TranslationDirectionResolver.target(for: "Hello", preferredTarget: .japanese),
            .japanese
        )
    }

    func testDeepLXDefaultEndpointRequiresAPIKeyToBeConfigured() {
        // Regression: DeepLX's default endpoint embeds "{{apiKey}}" in the path,
        // so DeepLXTranslationProvider.buildRequest throws missingAPIKey when no
        // key is set. isConfigured/isUsable must reflect that — otherwise the OCR
        // panel advertises DeepLX as ready while the first translation fails.
        let configKey = "translation.deeplx.config"
        let enabledKey = "translation.deeplx.enabled"
        let defaults = UserDefaults.standard

        let savedConfig = defaults.object(forKey: configKey)
        let savedEnabled = defaults.object(forKey: enabledKey)
        defer {
            if let savedConfig {
                defaults.set(savedConfig, forKey: configKey)
            } else {
                defaults.removeObject(forKey: configKey)
            }
            if let savedEnabled {
                defaults.set(savedEnabled, forKey: enabledKey)
            } else {
                defaults.removeObject(forKey: enabledKey)
            }
        }

        defaults.removeObject(forKey: configKey)
        TranslationConfigStore.setEnabled(true, for: .deeplx)

        // Default endpoint (contains "{{apiKey}}") + no key -> not configured.
        XCTAssertFalse(TranslationConfigStore.isConfigured(.deeplx))
        XCTAssertFalse(TranslationConfigStore.isUsable(.deeplx))

        // Self-hosted endpoint without the placeholder stays usable key-less.
        TranslationConfigStore.save(
            TranslationConfig(endpoint: "https://deeplx.example.com/translate"),
            for: .deeplx
        )
        XCTAssertTrue(TranslationConfigStore.isConfigured(.deeplx))
        XCTAssertTrue(TranslationConfigStore.isUsable(.deeplx))

        // Default endpoint with a real key is configured again.
        TranslationConfigStore.save(TranslationConfig(apiKey: "real-key"), for: .deeplx)
        XCTAssertTrue(TranslationConfigStore.isConfigured(.deeplx))
    }

    private func requestBody(for kind: TranslationProviderKind) throws -> [String: Any] {
        let request = try TranslationService.buildRequest(
            text: "Hello",
            system: "Translate",
            kind: kind,
            config: TranslationConfig(
                apiKey: "test-key",
                model: kind == .custom ? "test-model" : "",
                endpoint: kind == .custom ? "https://example.com/v1/chat/completions" : ""
            )
        )
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
