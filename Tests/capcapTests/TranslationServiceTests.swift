import AppKit
import Foundation
import XCTest
@testable import capcap

final class TranslationServiceTests: XCTestCase {
    func testAppleTranslationProviderHasNoRemoteConfigurationRequirements() {
        XCTAssertTrue(TranslationProviderKind.apple.isDirectTranslationAPI)
        XCTAssertFalse(TranslationProviderKind.apple.isAPIKeyRequired)
        XCTAssertEqual(TranslationProviderKind.apple.defaultEndpoint, "")
        XCTAssertEqual(TranslationProviderKind.apple.defaultModel, "")
    }

    func testAppleTranslationProviderFollowsSystemAvailability() {
        if #available(macOS 15.0, *) {
            XCTAssertTrue(TranslationProviderKind.apple.isAvailableOnCurrentSystem)
            XCTAssertTrue(TranslationConfigStore.orderedKinds().contains(.apple))
        } else {
            XCTAssertFalse(TranslationProviderKind.apple.isAvailableOnCurrentSystem)
            XCTAssertFalse(TranslationConfigStore.orderedKinds().contains(.apple))
        }
    }

    func testAppleTranslationWithoutPanelSessionFailsClearly() async {
        let stream = TranslationService.stream(
            text: "Hello",
            target: .chinese,
            kind: .apple,
            config: TranslationConfig()
        )

        do {
            for try await _ in stream {}
            XCTFail("Expected Apple Translation to require a panel session")
        } catch TranslationServiceError.appleTranslationUnavailable {
            // Expected: macOS 15-25 sessions must be supplied by a hosted view.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

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

    @MainActor
    func testExplicitTranslationTargetIsPassedToProvider() async throws {
        let provider = RecordingAppleTranslationProvider()
        let cases: [(text: String, target: TranslationLanguage)] = [
            ("你好，世界", .chinese),
            ("Hello", .english),
            ("TokenPlanPlus极速版-年度会员", .chinese),
        ]

        for (text, target) in cases {
            let stream = TranslationService.stream(
                text: text,
                target: target,
                kind: .apple,
                config: TranslationConfig(),
                appleProvider: provider
            )
            for try await _ in stream {}
        }

        XCTAssertEqual(provider.targets, cases.map { $0.target })
    }

    func testAutomaticChineseInputResolvesToEnglish() async {
        for text in ["你好，世界", "繁體中文測試"] {
            let target = await TranslationDirectionResolver.automaticTarget(for: text, preferredTarget: .chinese)
            XCTAssertEqual(target, .english)
        }
    }

    func testAutomaticEnglishInputResolvesToChinese() async {
        for preferredTarget in [TranslationLanguage.chinese, .english] {
            let target = await TranslationDirectionResolver.automaticTarget(for: "Hello", preferredTarget: preferredTarget)
            XCTAssertEqual(target, .chinese)
        }
    }

    func testAutomaticMixedChineseTechnicalTextResolvesToEnglish() async {
        let target = await TranslationDirectionResolver.automaticTarget(
            for: "请优化 API response 的 latency",
            preferredTarget: .chinese
        )
        XCTAssertEqual(target, .english)
    }

    func testAutomaticChineseTargetIsPreservedForScatteredChineseWordsInEnglish() async {
        let target = await TranslationDirectionResolver.automaticTarget(
            for: "Open 配置 in your account settings and select 会员 to view the renewal dates and billing options for your membership",
            preferredTarget: .chinese
        )
        XCTAssertEqual(target, .chinese)
    }

    func testAutomaticModeKeepsPreferredTargetForDifferentSourceLanguage() async {
        let target = await TranslationDirectionResolver.automaticTarget(for: "Hello", preferredTarget: .japanese)
        XCTAssertEqual(target, .japanese)
    }

    func testTargetPreferenceRestoresFixedLanguageAndCanReturnToAutomatic() {
        let defaults = UserDefaults.standard
        let key = "translation.targetLanguage"
        let original = defaults.object(forKey: key)
        defer { defaults.set(original, forKey: key) }

        defaults.set("zh", forKey: key)
        XCTAssertEqual(Defaults.translationTargetLanguage, .chinese)

        Defaults.translationTargetLanguage = .english
        XCTAssertEqual(defaults.string(forKey: key), "en")

        Defaults.translationTargetLanguage = nil
        XCTAssertNil(defaults.object(forKey: key))
        XCTAssertNil(Defaults.translationTargetLanguage)
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

@MainActor
private final class RecordingAppleTranslationProvider: AppleTranslationSessionProviding {
    let hostView = NSView()
    private(set) var targets: [TranslationLanguage] = []

    func translate(text: String, target: TranslationLanguage) async throws -> String {
        targets.append(target)
        return text
    }

    func cancel() {}
}
