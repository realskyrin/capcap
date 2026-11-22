import AppKit

final class SourceAppFocusRestorer {
    private let processIdentifier: pid_t?
    private var restoreScheduled = false

    private init(processIdentifier: pid_t?) {
        self.processIdentifier = processIdentifier
    }

    static func captureFrontmostApplication() -> SourceAppFocusRestorer {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let app = NSWorkspace.shared.frontmostApplication
        let targetPID = app?.processIdentifier == ownPID ? nil : app?.processIdentifier
        return SourceAppFocusRestorer(processIdentifier: targetPID)
    }

    func restore() {
        guard !restoreScheduled else { return }
        restoreScheduled = true

        DispatchQueue.main.async { [self] in
            guard
                let processIdentifier,
                let app = NSRunningApplication(processIdentifier: processIdentifier),
                !app.isTerminated,
                !app.isActive,
                app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else {
                return
            }

            // Return keyboard focus without raising sibling windows on other displays.
            app.activate(options: [])
        }
    }
}
