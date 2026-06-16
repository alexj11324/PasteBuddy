import AppKit

struct ExternalApplicationIdentity {
    let localizedName: String
    let bundleIdentifier: String?
    let processIdentifier: pid_t
}

@MainActor
final class FrontmostApplicationTracker {
    private var activationObserver: NSObjectProtocol?
    private var lastExternalApplication: NSRunningApplication?
    private let selfBundleIdentifiers = Set(
        [Bundle.main.bundleIdentifier, "com.pastebuddy.app"].compactMap(\.self)
    )

    deinit {
        MainActor.assumeIsolated {
            if let activationObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            }
        }
    }

    func start() {
        guard activationObserver == nil else { return }
        recordCurrentFrontmostApplication()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor in
                self?.recordIfExternal(application)
            }
        }
    }

    func recordCurrentFrontmostApplication() {
        recordIfExternal(NSWorkspace.shared.frontmostApplication)
    }

    func currentExternalApplication() -> ExternalApplicationIdentity? {
        guard let application = lastExternalApplication,
              !application.isTerminated,
              isExternal(application)
        else {
            return nil
        }
        return ExternalApplicationIdentity(
            localizedName: application.localizedName ?? "Unknown App",
            bundleIdentifier: application.bundleIdentifier,
            processIdentifier: application.processIdentifier
        )
    }

    func frontmostApplicationBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    @discardableResult
    func activateLastExternalApplication() -> Bool {
        guard let application = lastExternalApplication,
              !application.isTerminated,
              isExternal(application)
        else {
            return false
        }
        return application.activate(options: [])
    }

    func waitForActivation(of bundleIdentifier: String, timeout: TimeInterval) async -> Bool {
        let normalizedTarget = Self.normalizedBundleIdentifier(bundleIdentifier)
        guard let normalizedTarget else { return false }
        if Self.normalizedBundleIdentifier(frontmostApplicationBundleIdentifier()) == normalizedTarget {
            return true
        }

        let notificationCenter = NSWorkspace.shared.notificationCenter
        return await withCheckedContinuation { continuation in
            let waiter = FrontmostApplicationActivationWaiter(continuation: continuation)
            waiter.observer = notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [waiter] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      Self.normalizedBundleIdentifier(application.bundleIdentifier) == normalizedTarget else {
                    return
                }
                Task { @MainActor [waiter] in
                    waiter.resume(true)
                }
            }

            Task { @MainActor [waiter] in
                let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
                if nanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: nanoseconds)
                }
                waiter.resume(false)
            }
        }
    }

    private func recordIfExternal(_ application: NSRunningApplication?) {
        guard let application, isExternal(application) else { return }
        lastExternalApplication = application
    }

    private func isExternal(_ application: NSRunningApplication) -> Bool {
        if application.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return false
        }
        if let bundleIdentifier = application.bundleIdentifier,
           selfBundleIdentifiers.contains(bundleIdentifier) {
            return false
        }
        return true
    }

    nonisolated private static func normalizedBundleIdentifier(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}

@MainActor
private final class FrontmostApplicationActivationWaiter {
    var observer: NSObjectProtocol?
    private var didResume = false
    private let continuation: CheckedContinuation<Bool, Never>

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ result: Bool) {
        guard !didResume else { return }
        didResume = true
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        continuation.resume(returning: result)
    }
}
