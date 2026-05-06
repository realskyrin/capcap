import AppKit

/// Coordinates the active upload: shows the floating progress chip, runs the
/// provider upload, copies the URL on success, surfaces a toast either way.
final class UploadManager {
    static let shared = UploadManager()

    private var inFlight = false
    private var progressWindow: UploadProgressWindow?

    private init() {}

    func upload(image: NSImage, on screen: NSScreen?) {
        guard !inFlight else { return }
        guard let kind = Defaults.defaultUploadProviderKind else {
            ToastWindow.show(message: L10n.uploadNoProvider, on: screen)
            return
        }
        guard let config = ProviderConfigStore.load(kind: kind) else {
            ToastWindow.show(message: L10n.uploadNoProvider, on: screen)
            return
        }
        let providerType = Uploaders.provider(for: kind)
        if let err = providerType.validate(config) {
            ToastWindow.show(message: err, on: screen)
            return
        }
        guard let pngData = image.pngDataPreservingBacking() else {
            ToastWindow.show(message: L10n.uploadFailedPrefix + "PNG encode", on: screen)
            return
        }

        inFlight = true
        let fileName = Self.makeFileName()

        let window = UploadProgressWindow(provider: kind.displayName)
        window.show(on: screen)
        progressWindow = window

        providerType.upload(
            data: pngData,
            fileName: fileName,
            config: config,
            progress: { [weak self] pct in
                self?.progressWindow?.setProgress(pct)
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.inFlight = false
                self.progressWindow?.dismiss()
                self.progressWindow = nil
                switch result {
                case .success(let url):
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(url.absoluteString, forType: .string)
                    ToastWindow.show(message: L10n.uploadCopied, on: screen)
                case .failure(let err):
                    let msg = (err as? UploadError)?.errorDescription
                        ?? err.localizedDescription
                    ToastWindow.show(message: L10n.uploadFailedPrefix + msg, on: screen)
                }
            }
        )
    }

    private static func makeFileName() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = fmt.string(from: Date())
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        return "capcap-\(stamp)-\(suffix).png"
    }
}
