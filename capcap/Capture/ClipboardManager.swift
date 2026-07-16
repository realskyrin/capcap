import AppKit

private let skipClipboardHistoryPasteboardType = NSPasteboard.PasteboardType(
    "cn.skyrin.capcap.skip-clipboard-text-history"
)

enum ClipboardColorParser {
    static func normalizedHex(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }

        let digits = trimmed.dropFirst()
        guard digits.count == 6, UInt32(digits, radix: 16) != nil else { return nil }
        return "#" + digits.uppercased()
    }
}

struct ClipboardManager {
    static func copyToClipboard(image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if let pngData = image.pngDataPreservingBacking() {
            pasteboard.setData(pngData, forType: .png)
        }

        if let tiffData = image.tiffDataPreservingBacking() {
            pasteboard.setData(tiffData, forType: .tiff)
        }
    }

    static func copyToClipboard(imageOutput: EncodedClipboardImageOutput) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(imageOutput.primary.data, forType: imageOutput.primary.pasteboardType)
        if let tiffData = imageOutput.tiffData {
            pasteboard.setData(tiffData, forType: .tiff)
        }
    }

    static func copyToClipboard(text: String) {
        writeTextToClipboard(text)
    }

    static func copyColorToClipboard(hex: String) {
        guard let normalizedHex = ClipboardColorParser.normalizedHex(from: hex) else {
            writeTextToClipboard(hex)
            return
        }
        writeTextToClipboard(normalizedHex, skipHistory: true)
    }

    static func copyHistoryTextToClipboard(_ text: String) {
        writeTextToClipboard(text, skipHistory: true)
    }

    private static func writeTextToClipboard(_ text: String, skipHistory: Bool = false) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if skipHistory {
            pasteboard.setString("1", forType: skipClipboardHistoryPasteboardType)
        }
    }
}

final class ClipboardTextHistoryMonitor: NSObject {
    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount = 0
    private var isStarted = false

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        timer?.invalidate()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        lastChangeCount = pasteboard.changeCount
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cacheSettingChanged),
            name: .clipboardTextCacheEnabledDidChange,
            object: nil
        )
        updateTimerState()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        NotificationCenter.default.removeObserver(self)
        stopTimer()
    }

    @objc private func cacheSettingChanged() {
        lastChangeCount = pasteboard.changeCount
        updateTimerState()
    }

    private func updateTimerState() {
        if Defaults.clipboardTextCacheEnabled {
            startTimer()
        } else {
            stopTimer()
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollPasteboard()
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func pollPasteboard() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        guard Defaults.clipboardTextCacheEnabled,
              pasteboard.availableType(from: [skipClipboardHistoryPasteboardType]) == nil,
              let text = pasteboard.string(forType: .string),
              !text.isEmpty else { return }
        if Defaults.historyCacheEnabled,
           let hex = ClipboardColorParser.normalizedHex(from: text) {
            HistoryManager.shared.addColor(hex: hex)
        } else {
            HistoryManager.shared.addText(text)
        }
    }
}
