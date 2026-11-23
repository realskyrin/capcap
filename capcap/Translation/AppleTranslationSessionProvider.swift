import AppKit
import Foundation

/// Narrow interface used by the AppKit translation panel. The concrete bridge
/// is isolated below because macOS 15-25 only vend TranslationSession through a
/// SwiftUI view modifier; no public AppKit session initializer exists there.
@MainActor
protocol AppleTranslationSessionProviding: AnyObject {
    var hostView: NSView { get }
    func translate(text: String, target: TranslationLanguage) async throws -> String
    func cancel()
}

@MainActor
enum AppleTranslationSessionProviderFactory {
    static func makeProvider() -> AppleTranslationSessionProviding? {
#if canImport(Translation) && canImport(SwiftUI)
        guard #available(macOS 15.0, *) else { return nil }
        return AppleTranslationSessionProvider()
#else
        return nil
#endif
    }
}

#if canImport(Translation) && canImport(SwiftUI)
import NaturalLanguage
import SwiftUI
import Translation

@available(macOS 15.0, *)
@MainActor
private final class AppleTranslationSessionProvider: AppleTranslationSessionProviding {
    private let model = AppleTranslationBridgeModel()

    lazy var hostView: NSView = {
        NSHostingView(rootView: AppleTranslationBridgeView(model: model))
    }()

    func translate(text: String, target: TranslationLanguage) async throws -> String {
        try await model.translate(text: text, target: target)
    }

    func cancel() {
        model.cancel()
    }
}

@available(macOS 15.0, *)
@MainActor
private final class AppleTranslationBridgeModel: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?

    private struct PendingRequest {
        let id: UUID
        let text: String
        let targetLanguage: Locale.Language
        let continuation: CheckedContinuation<String, Error>
    }

    private var pendingRequest: PendingRequest?
    var pendingRequestID: UUID? { pendingRequest?.id }

    func translate(text: String, target: TranslationLanguage) async throws -> String {
        let requestID = UUID()
        let targetLanguage = Locale.Language(identifier: target.localeIdentifier)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRequest?.continuation.resume(throwing: CancellationError())
                pendingRequest = PendingRequest(
                    id: requestID,
                    text: text,
                    targetLanguage: targetLanguage,
                    continuation: continuation
                )

                var nextConfiguration = TranslationSession.Configuration(
                    source: nil,
                    target: targetLanguage
                )
                if let current = configuration,
                   current.source == nil,
                   current.target == targetLanguage {
                    nextConfiguration = current
                    nextConfiguration.invalidate()
                }
                configuration = nextConfiguration
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(requestID: requestID)
            }
        }
    }

    func performPendingTranslation(using session: TranslationSession, requestID: UUID?) async {
        guard !Task.isCancelled, let request = pendingRequest,
              request.id == requestID else { return }
        do {
            let response = try await session.translate(request.text)
            finish(requestID: request.id, result: .success(response.targetText))
        } catch {
            // Apple rejects same-language pairs. Preserve the text only when
            // recognition also matches the requested language and script.
            if TranslationError.unsupportedLanguagePairing ~= error,
               await Self.alreadyInTargetLanguage(request.text, target: request.targetLanguage) {
                finish(requestID: request.id, result: .success(request.text))
            } else {
                finish(requestID: request.id, result: .failure(error))
            }
        }
    }

    private nonisolated static func alreadyInTargetLanguage(_ text: String, target: Locale.Language) async -> Bool {
        guard let source = NLLanguageRecognizer.dominantLanguage(for: text) else { return false }
        return Locale.Language(identifier: source.rawValue) == target
    }

    func cancel() {
        guard let request = pendingRequest else {
            configuration = nil
            return
        }
        pendingRequest = nil
        configuration = nil
        request.continuation.resume(throwing: CancellationError())
    }

    private func cancel(requestID: UUID) {
        guard pendingRequest?.id == requestID else { return }
        cancel()
    }

    private func finish(requestID: UUID, result: Result<String, Error>) {
        guard let request = pendingRequest, request.id == requestID else { return }
        pendingRequest = nil
        configuration = nil
        request.continuation.resume(with: result)
    }
}

@available(macOS 15.0, *)
private struct AppleTranslationBridgeView: View {
    @ObservedObject var model: AppleTranslationBridgeModel

    var body: some View {
        let requestID = model.pendingRequestID
        Color.clear
            .allowsHitTesting(false)
            .translationTask(model.configuration) { session in
                await model.performPendingTranslation(using: session, requestID: requestID)
            }
    }
}
#endif
