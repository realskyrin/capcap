import CoreGraphics
import Foundation
import ScreenCaptureKit

struct ScreenSnapshotTarget: Sendable {
    let displayID: CGDirectDisplayID
    let bounds: CGRect
    let scale: CGFloat
}

enum ScreenSnapshotEvent: @unchecked Sendable {
    case image(displayID: CGDirectDisplayID, image: CGImage)
    case failure(displayID: CGDirectDisplayID, error: Error)
    case finished
}

typealias ScreenSnapshotCancellation = () -> Void

protocol ScreenSnapshotProviding {
    func prewarm()

    @discardableResult
    func capture(
        targets: [ScreenSnapshotTarget],
        eventHandler: @escaping (ScreenSnapshotEvent) -> Void
    ) -> ScreenSnapshotCancellation
}

final class ScreenSnapshotProvider: ScreenSnapshotProviding {
    static let shared = ScreenSnapshotProvider()

    private let contentCache = ScreenSnapshotContentCache()
    private let cacheEpoch = ScreenSnapshotCacheEpoch()

    private init() {}

    func prewarm() {
        let contentCache = contentCache
        let cacheEpoch = cacheEpoch.current
        let processID = ProcessInfo.processInfo.processIdentifier
        Task.detached(priority: .utility) {
            do {
                _ = try await contentCache.captureContent(
                    requiredDisplayIDs: [],
                    processID: processID,
                    cacheEpoch: cacheEpoch
                )
            } catch {
                NSLog("capcap: Screen snapshot prewarm failed: \(error)")
            }
        }
    }

    func invalidateAndPrewarm(displayIDs: Set<CGDirectDisplayID>) {
        let contentCache = contentCache
        let cacheEpoch = cacheEpoch.advance()
        let processID = ProcessInfo.processInfo.processIdentifier
        Task.detached(priority: .utility) {
            do {
                _ = try await contentCache.captureContent(
                    requiredDisplayIDs: displayIDs,
                    processID: processID,
                    cacheEpoch: cacheEpoch
                )
            } catch is CancellationError {
                return
            } catch {
                NSLog("capcap: Screen snapshot metadata refresh failed: \(error)")
            }
        }
    }

    @discardableResult
    func capture(
        targets: [ScreenSnapshotTarget],
        eventHandler: @escaping (ScreenSnapshotEvent) -> Void
    ) -> ScreenSnapshotCancellation {
        let delivery = ScreenSnapshotEventDelivery(eventHandler: eventHandler)
        let contentCache = contentCache
        let requiredDisplayIDs = Set(targets.map(\.displayID))
        let cacheEpoch = cacheEpoch.current
        let processID = ProcessInfo.processInfo.processIdentifier

        let task = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return }

            do {
                let captureContent = try await contentCache.captureContent(
                    requiredDisplayIDs: requiredDisplayIDs,
                    processID: processID,
                    cacheEpoch: cacheEpoch
                )
                guard !Task.isCancelled else { return }

                await withTaskGroup(of: ScreenSnapshotEvent.self) { group in
                    for target in targets {
                        group.addTask {
                            await Self.capture(
                                target: target,
                                content: captureContent.content,
                                ownApplication: captureContent.ownApplication
                            )
                        }
                    }

                    for await event in group {
                        guard !Task.isCancelled else {
                            group.cancelAll()
                            return
                        }
                        delivery.send(event)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                for target in targets {
                    delivery.send(.failure(displayID: target.displayID, error: error))
                }
            }

            guard !Task.isCancelled else { return }
            delivery.send(.finished)
        }

        return {
            delivery.cancel()
            task.cancel()
        }
    }

    private static func capture(
        target: ScreenSnapshotTarget,
        content: SCShareableContent,
        ownApplication: SCRunningApplication
    ) async -> ScreenSnapshotEvent {
        guard target.bounds.width > 0,
              target.bounds.height > 0,
              target.scale > 0 else {
            return .failure(
                displayID: target.displayID,
                error: ScreenSnapshotProviderError.invalidTarget(displayID: target.displayID)
            )
        }

        guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
            return .failure(
                displayID: target.displayID,
                error: ScreenSnapshotProviderError.displayNotFound(displayID: target.displayID)
            )
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [ownApplication],
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.width = max(Int(ceil(target.bounds.width * target.scale)), 1)
        configuration.height = max(Int(ceil(target.bounds.height * target.scale)), 1)
        configuration.capturesAudio = false
        configuration.showsCursor = false
        configuration.captureResolution = .best

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return .image(displayID: target.displayID, image: image)
        } catch {
            return .failure(displayID: target.displayID, error: error)
        }
    }
}

private struct ScreenSnapshotCaptureContent: @unchecked Sendable {
    let content: SCShareableContent
    let ownApplication: SCRunningApplication
}

private final class ScreenSnapshotCacheEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var current: Int {
        lock.withLock { value }
    }

    func advance() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

private actor ScreenSnapshotContentCache {
    private struct ContentLoad {
        let id: UUID
        let task: Task<SCShareableContent, Error>
    }

    private var cachedContent: SCShareableContent?
    private var cachedOwnApplication: SCRunningApplication?
    private var loading: ContentLoad?
    private var activeEpoch = 0

    func captureContent(
        requiredDisplayIDs: Set<CGDirectDisplayID>,
        processID: pid_t,
        cacheEpoch: Int
    ) async throws -> ScreenSnapshotCaptureContent {
        synchronize(to: cacheEpoch)
        let content = try await displayContent(
            requiredDisplayIDs: requiredDisplayIDs,
            cacheEpoch: cacheEpoch
        )
        try validate(cacheEpoch)
        do {
            let captureContent = try await captureContent(
                content: content,
                processID: processID,
                cacheEpoch: cacheEpoch
            )
            try validate(cacheEpoch)
            return captureContent
        } catch ScreenSnapshotProviderError.applicationNotFound {
            // On macOS 14.0-14.3, prewarming before capcap owns a window can
            // yield content without this process. Do not permanently reuse it.
            cachedContent = nil
            cachedOwnApplication = nil
            let refreshedContent = try await displayContent(
                requiredDisplayIDs: requiredDisplayIDs,
                cacheEpoch: cacheEpoch
            )
            try validate(cacheEpoch)
            let captureContent = try await captureContent(
                content: refreshedContent,
                processID: processID,
                cacheEpoch: cacheEpoch
            )
            try validate(cacheEpoch)
            return captureContent
        }
    }

    private func captureContent(
        content: SCShareableContent,
        processID: pid_t,
        cacheEpoch: Int
    ) async throws -> ScreenSnapshotCaptureContent {
        let ownApplication = try await ownApplication(
            processID: processID,
            fallbackContent: content,
            cacheEpoch: cacheEpoch
        )
        return ScreenSnapshotCaptureContent(
            content: content,
            ownApplication: ownApplication
        )
    }

    private func displayContent(
        requiredDisplayIDs: Set<CGDirectDisplayID>,
        cacheEpoch: Int
    ) async throws -> SCShareableContent {
        try validate(cacheEpoch)
        if let cachedContent,
           isSuitable(
               cachedContent,
               requiredDisplayIDs: requiredDisplayIDs
           ) {
            return cachedContent
        }
        var content = try await loadFreshContent()
        try validate(cacheEpoch)
        if !isSuitable(
            content,
            requiredDisplayIDs: requiredDisplayIDs
        ) {
            cachedContent = nil
            content = try await loadFreshContent()
            try validate(cacheEpoch)
        }
        cachedContent = content
        return content
    }

    private func ownApplication(
        processID: pid_t,
        fallbackContent: SCShareableContent,
        cacheEpoch: Int
    ) async throws -> SCRunningApplication {
        try validate(cacheEpoch)
        if let cachedOwnApplication,
           cachedOwnApplication.processID == processID {
            return cachedOwnApplication
        }
        if let application = fallbackContent.applications.first(where: {
            $0.processID == processID
        }) {
            cachedOwnApplication = application
            return application
        }
        if #available(macOS 14.4, *) {
            let processContent = try await SCShareableContent.currentProcess
            try validate(cacheEpoch)
            if let application = processContent.applications.first(where: {
                $0.processID == processID
            }) {
                cachedOwnApplication = application
                return application
            }
        }
        throw ScreenSnapshotProviderError.applicationNotFound(processID: processID)
    }

    private func loadFreshContent() async throws -> SCShareableContent {
        if let loading {
            return try await loading.task.value
        }

        let id = UUID()
        let task = Task.detached(priority: .userInitiated) {
            try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        }
        loading = ContentLoad(id: id, task: task)

        do {
            let content = try await task.value
            if loading?.id == id {
                loading = nil
            }
            return content
        } catch {
            if loading?.id == id {
                loading = nil
            }
            throw error
        }
    }

    private func synchronize(to cacheEpoch: Int) {
        guard cacheEpoch > activeEpoch else { return }
        activeEpoch = cacheEpoch
        cachedContent = nil
        cachedOwnApplication = nil
        loading?.task.cancel()
        loading = nil
    }

    private func validate(_ cacheEpoch: Int) throws {
        guard cacheEpoch == activeEpoch else {
            throw CancellationError()
        }
    }

    private func isSuitable(
        _ content: SCShareableContent,
        requiredDisplayIDs: Set<CGDirectDisplayID>
    ) -> Bool {
        let displayIDs = Set(content.displays.map(\.displayID))
        return requiredDisplayIDs.isSubset(of: displayIDs)
    }
}

private final class ScreenSnapshotEventDelivery: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var eventHandler: ((ScreenSnapshotEvent) -> Void)?
    private var isCancelled = false

    init(eventHandler: @escaping (ScreenSnapshotEvent) -> Void) {
        self.eventHandler = eventHandler
    }

    func send(_ event: ScreenSnapshotEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return }
        eventHandler?(event)
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        eventHandler = nil
    }
}

private enum ScreenSnapshotProviderError: LocalizedError {
    case invalidTarget(displayID: CGDirectDisplayID)
    case displayNotFound(displayID: CGDirectDisplayID)
    case applicationNotFound(processID: pid_t)

    var errorDescription: String? {
        switch self {
        case let .invalidTarget(displayID):
            return "Invalid screen snapshot target for display \(displayID)"
        case let .displayNotFound(displayID):
            return "ScreenCaptureKit display \(displayID) was not found"
        case let .applicationNotFound(processID):
            return "ScreenCaptureKit application \(processID) was not found"
        }
    }
}
