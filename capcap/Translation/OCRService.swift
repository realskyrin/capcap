import AppKit
import ImageIO
@preconcurrency import Vision
import VisionKit

struct RecognizedTextToken: Equatable {
    let text: String
    /// Vision-normalized rectangle with bottom-left origin.
    let boundingBox: CGRect
}

struct RecognizedTextLine: Equatable {
    let text: String
    /// Vision-normalized rectangle with bottom-left origin.
    let boundingBox: CGRect
    let tokens: [RecognizedTextToken]

    init(text: String, boundingBox: CGRect, tokens: [RecognizedTextToken] = []) {
        self.text = text
        self.boundingBox = boundingBox
        self.tokens = tokens
    }
}

/// Apple OCR helpers. Live Text uses VisionKit where available; the fallback
/// path remains `VNRecognizeTextRequest` in accurate mode.
enum OCRService {
    private static let preferredRecognitionLanguages = [
        "zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"
    ]

    /// Recognizes text in `image` and returns it as newline-joined lines,
    /// ordered top-to-bottom then left-to-right. Returns an empty string when
    /// nothing is found or the image cannot be decoded.
    static func recognize(image: NSImage) async -> String {
        if let analysis = await analyzeText(image: image) {
            let transcript = analysis.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty {
                return transcript
            }
        }

        return await recognizeLines(image: image)
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs the same system Live Text analyzer used by Preview. The returned
    /// analysis can be attached to `ImageAnalysisOverlayView` for native text
    /// selection, menus, and keyboard copy.
    static func analyzeText(image: NSImage) async -> ImageAnalysis? {
        guard ImageAnalyzer.isSupported else { return nil }

        let configuration = ImageAnalyzer.Configuration(.text)

        do {
            let analysis = try await ImageAnalyzer().analyze(
                image,
                orientation: .up,
                configuration: configuration
            )
            return analysis.hasResults(for: .text) ? analysis : nil
        } catch {
            return nil
        }
    }

    /// Recognizes text in `image` and returns ordered text lines with their
    /// source rectangles so result panels can draw per-line copy targets.
    static func recognizeLines(image: NSImage) async -> [RecognizedTextLine] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                continuation.resume(returning: Self.assembleLines(observations))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // Bias toward CJK + Latin scripts; auto-detect still kicks in for
            // anything outside this list.
            request.recognitionLanguages = preferredRecognitionLanguages
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    // perform() failing means the completion handler never
                    // ran — resume here so the continuation isn't leaked.
                    continuation.resume(returning: [])
                }
            }
        }
    }

    /// Orders observations into natural reading order. Vision bounding boxes
    /// are normalized with a bottom-left origin, so a larger `midY` means a
    /// higher line on screen.
    private static func assembleLines(_ observations: [VNRecognizedTextObservation]) -> [RecognizedTextLine] {
        let sorted = observations.sorted { a, b in
            // Treat lines whose vertical centers are close as the same row and
            // fall back to horizontal order.
            if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.012 {
                return a.boundingBox.midY > b.boundingBox.midY
            }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        return sorted
            .compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let rawText = candidate.string
                guard let contentRange = rawText.nonWhitespaceRange else { return nil }
                let text = String(rawText[contentRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return RecognizedTextLine(
                    text: text,
                    boundingBox: observation.boundingBox,
                    tokens: Self.tokens(in: rawText, contentRange: contentRange, candidate: candidate)
                )
            }
    }

    private static func tokens(
        in rawText: String,
        contentRange: Range<String.Index>,
        candidate: VNRecognizedText
    ) -> [RecognizedTextToken] {
        var tokens: [RecognizedTextToken] = []
        var index = contentRange.lowerBound

        while index < contentRange.upperBound {
            if rawText[index].isWhitespace {
                index = rawText.index(after: index)
                continue
            }

            let start = index
            if rawText[index].isCJKLike {
                index = rawText.index(after: index)
            } else {
                repeat {
                    index = rawText.index(after: index)
                } while index < contentRange.upperBound
                    && !rawText[index].isWhitespace
                    && !rawText[index].isCJKLike
            }

            let range = start..<index
            guard let observation = try? candidate.boundingBox(for: range) else { continue }
            let text = String(rawText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            tokens.append(RecognizedTextToken(text: text, boundingBox: observation.boundingBox))
        }

        return tokens
    }

}

private extension String {
    var nonWhitespaceRange: Range<String.Index>? {
        guard let first = firstIndex(where: { !$0.isWhitespace }),
              let last = lastIndex(where: { !$0.isWhitespace }) else {
            return nil
        }
        return first..<index(after: last)
    }
}

private extension Character {
    var isCJKLike: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, // Hiragana + Katakana
                 0x3400...0x4DBF, // CJK Extension A
                 0x4E00...0x9FFF, // CJK Unified Ideographs
                 0xAC00...0xD7AF, // Hangul Syllables
                 0xF900...0xFAFF: // CJK Compatibility Ideographs
                return true
            default:
                return false
            }
        }
    }
}
