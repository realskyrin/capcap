import AppKit

private let skipClipboardTextHistoryPasteboardType = NSPasteboard.PasteboardType(
    "cn.skyrin.capcap.skip-clipboard-text-history"
)

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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func copyHistoryTextToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("1", forType: skipClipboardTextHistoryPasteboardType)
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
              pasteboard.availableType(from: [skipClipboardTextHistoryPasteboardType]) == nil,
              let text = pasteboard.string(forType: .string),
              !text.isEmpty else { return }
        HistoryManager.shared.addText(text)
    }
}
