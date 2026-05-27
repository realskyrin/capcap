import AppKit
import Vision

struct RecognizedTextLine: Equatable {
    let text: String
    /// Vision-normalized rectangle with bottom-left origin.
    let boundingBox: CGRect
}

/// Apple Vision based text recognition. No third-party dependencies — the
/// whole OCR path is `VNRecognizeTextRequest` in accurate mode.
enum OCRService {

    /// Recognizes text in `image` and returns it as newline-joined lines,
    /// ordered top-to-bottom then left-to-right. Returns an empty string when
    /// nothing is found or the image cannot be decoded.
    static func recognize(image: NSImage) async -> String {
        await recognizeLines(image: image)
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "vi-VN", "ja-JP", "ko-KR"]
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
                guard let text = observation.topCandidates(1).first?.string
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty
                else { return nil }
                return RecognizedTextLine(text: text, boundingBox: observation.boundingBox)
            }
    }
}
