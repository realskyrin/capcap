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

/// OCR routing plus Apple recognition helpers. Native Live Text remains
/// exclusive to Apple results so it cannot replace another provider's text.
enum OCRService {
    private static let preferredRecognitionLanguages = [
        "zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"
    ]

    @MainActor
    static func recognizeResult(image: NSImage) async throws -> OCRResult {
        let kind = Defaults.ocrProviderKind
        let config = OCRConfigStore.load(kind)
        return try await recognizeResult(image: image, kind: kind, config: config)
    }

    static func recognizeResult(image: NSImage, kind: OCRProviderKind,
                                config: OCRProviderConfig) async throws -> OCRResult {
        try Task.checkCancellation()
        if kind == .apple {
            do {
                return try await AsyncDeadline.run(seconds: 65) {
                    let lines = try await recognizeLinesThrowing(image: image)
                    try Task.checkCancellation()
                    if !lines.isEmpty { return OCRResult(lines: lines, provider: kind) }
                    let analysis = try await analyzeTextThrowing(image: image)
                    try Task.checkCancellation()
                    return OCRResult(text: analysis?.transcript ?? "", provider: kind)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch is AsyncDeadline.TimedOut {
                throw OCRProviderError.timeout
            } catch OCRProviderError.image {
                throw OCRProviderError.image
            } catch {
                throw OCRProviderError.response
            }
        }
        do {
            return try await AsyncDeadline.run(seconds: 65) {
                try await NetworkOCRProvider.recognize(image: image, kind: kind, config: config)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch is AsyncDeadline.TimedOut {
            throw OCRProviderError.timeout
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw OCRProviderError.timeout }
            throw OCRProviderError.service(String(error.errorCode))
        } catch let error as OCRProviderError {
            throw error
        } catch {
            throw OCRProviderError.response
        }
    }

    /// Recognizes text in `image` and returns it as newline-joined lines,
    /// ordered top-to-bottom then left-to-right. Returns an empty string when
    /// nothing is found or the image cannot be decoded.
    static func recognize(image: NSImage) async -> String {
        let lines = await recognizeLines(image: image)
        guard !Task.isCancelled else { return "" }
        if !lines.isEmpty {
            return lines.map(\.text).joined(separator: "\n")
        }
        if let analysis = await analyzeText(image: image) {
            return analysis.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// Runs the same system Live Text analyzer used by Preview. The returned
    /// analysis can be attached to `ImageAnalysisOverlayView` for native text
    /// selection, menus, and keyboard copy.
    static func analyzeText(image: NSImage) async -> ImageAnalysis? {
        do {
            return try await AsyncDeadline.run(seconds: 3) {
                try await analyzeTextThrowing(image: image)
            }
        } catch {
            return nil
        }
    }

    /// Required text extraction shares the foreground deadline, unlike the
    /// best-effort overlay wrapper above.
    private static func analyzeTextThrowing(image: NSImage) async throws -> ImageAnalysis? {
        try Task.checkCancellation()
        guard ImageAnalyzer.isSupported else { return nil }
        let cgImage = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: image.cgImage(
                    forProposedRect: nil, context: nil, hints: nil
                ))
            }
        }
        try Task.checkCancellation()
        guard let cgImage else { throw OCRProviderError.image }
        let analysis = try await ImageAnalyzer().analyze(
            cgImage,
            orientation: .up,
            configuration: ImageAnalyzer.Configuration(.text)
        )
        try Task.checkCancellation()
        return analysis.hasResults(for: .text) ? analysis : nil
    }

    /// Recognizes text in `image` and returns ordered text lines with their
    /// source rectangles so result panels can draw per-line copy targets.
    static func recognizeLines(image: NSImage) async -> [RecognizedTextLine] {
        return (try? await AsyncDeadline.run(seconds: 15) {
            try await recognizeLinesThrowing(image: image)
        }) ?? []
    }

    private static func recognizeLinesThrowing(image: NSImage) async throws -> [RecognizedTextLine] {
        try Task.checkCancellation()
        let work = RecognitionWork()
        // Read results after synchronous perform returns. Its completion handler
        // can run before perform throws; resuming from both paths was unsafe.
        let lines = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try autoreleasepool { try work.recognize(image: image) }
                    })
                }
            }
        } onCancel: {
            work.cancel()
        }
        try Task.checkCancellation()
        return lines
    }

    private final class RecognitionWork: @unchecked Sendable {
        private let lock = NSLock()
        private var request: VNRecognizeTextRequest?
        private var cancelled = false

        func recognize(image: NSImage) throws -> [RecognizedTextLine] {
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw OCRProviderError.image
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = OCRService.preferredRecognitionLanguages
            request.automaticallyDetectsLanguage = true

            lock.lock()
            guard !cancelled else { lock.unlock(); throw CancellationError() }
            self.request = request
            lock.unlock()

            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            return OCRService.assembleLines(request.results ?? [])
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let request = self.request
            lock.unlock()
            request?.cancel()
        }
    }

    /// Orders observations into natural reading order. Vision bounding boxes
    /// are normalized with a bottom-left origin, so a larger `midY` means a
    /// higher line on screen.
    private static func assembleLines(_ observations: [VNRecognizedTextObservation]) -> [RecognizedTextLine] {
        let fragments: [RecognizedTextLine] = observations
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
        return readingOrderLines(fragments)
    }

    /// Group by actual line height rather than a fixed fraction of the image.
    /// A fuzzy comparison inside `sorted` is not transitive, and emitting every
    /// observation on a new line turns widely spaced horizontal titles vertical.
    static func readingOrderLines(_ fragments: [RecognizedTextLine], joinsCJK: Bool = false) -> [RecognizedTextLine] {
        let sorted = fragments.sorted {
            if $0.boundingBox.midY != $1.boundingBox.midY {
                return $0.boundingBox.midY > $1.boundingBox.midY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        var rows: [[RecognizedTextLine]] = []
        for fragment in sorted {
            let box = fragment.boundingBox
            let matchingRow = rows.indices.filter { index in
                let reference = rows[index][0].boundingBox
                let height = min(box.height, reference.height)
                let overlap = min(box.maxY, reference.maxY) - max(box.minY, reference.minY)
                return height > 0 && overlap >= height * 0.5
                    && abs(box.midY - reference.midY) <= height * 0.5
            }.min { lhs, rhs in
                abs(rows[lhs][0].boundingBox.midY - box.midY)
                    < abs(rows[rhs][0].boundingBox.midY - box.midY)
            }
            if let matchingRow {
                rows[matchingRow].append(fragment)
            } else {
                rows.append([fragment])
            }
        }
        return rows.map { row in
            let ordered = row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            var text = ordered[0].text
            var bounds = ordered[0].boundingBox
            for index in ordered.indices.dropFirst() {
                let previous = ordered[index - 1]
                let fragment = ordered[index]
                let characterWidth = max(
                    previous.boundingBox.width / CGFloat(max(previous.text.count, 1)),
                    fragment.boundingBox.width / CGFloat(max(fragment.text.count, 1))
                )
                let gap = fragment.boundingBox.minX - previous.boundingBox.maxX
                if gap > characterWidth * 3 {
                    text += "\t"
                } else if !(joinsCJK && previous.text.last?.isCJKLike == true
                            && fragment.text.first?.isCJKLike == true && gap < characterWidth * 0.75) {
                    text += " "
                }
                text += fragment.text
                bounds = bounds.union(fragment.boundingBox)
            }
            return RecognizedTextLine(
                text: text,
                boundingBox: bounds,
                tokens: ordered.flatMap(\.tokens)
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
