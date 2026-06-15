import AppKit

struct ExternalApplicationIdentity {
    let localizedName: String
    let bundleIdentifier: String?
    let processIdentifier: pid_t
}

@MainActor
final class FrontmostApplicationTracker {
    nonisolated(unsafe) private var activationObserver: NSObjectProtocol?
    private weak var lastExternalApplication: NSRunningApplication?
    private let selfBundleIdentifiers = Set(
        [Bundle.main.bundleIdentifier, "com.pastebuddy.app"].compactMap(\.self)
    )

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
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
}
