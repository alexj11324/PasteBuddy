import Foundation
import OSLog
import PasteBuddyCore

enum PasteBuddyDiagnosticCategory: String, Sendable {
    case hotKey
    case shelf
    case directPaste
    case capture
    case pin
}

struct PasteBuddyDiagnosticEvent: Equatable, Sendable {
    var category: PasteBuddyDiagnosticCategory
    var name: String
    var detail: String?
}

enum PasteBuddyDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pastebuddy.app",
        category: "Diagnostics"
    )
    private static let store = PasteBuddyDiagnosticsStore()

    static func record(_ category: PasteBuddyDiagnosticCategory, _ name: String, detail: String? = nil) {
        let event = PasteBuddyDiagnosticEvent(category: category, name: name, detail: detail)
        if let detail {
            logger.info("[PasteBuddyDiagnostics] \(category.rawValue, privacy: .public).\(name, privacy: .public) \(detail, privacy: .public)")
        } else {
            logger.info("[PasteBuddyDiagnostics] \(category.rawValue, privacy: .public).\(name, privacy: .public)")
        }
        store.emit(event)
    }

    static func recordAccessibilityTrust(
        _ category: PasteBuddyDiagnosticCategory,
        _ name: String,
        isTrusted: Bool = AccessibilityPermissionService.isTrusted
    ) {
        record(category, name, detail: "trusted=\(isTrusted)")
    }

    static func installTestSink(_ sink: @escaping (PasteBuddyDiagnosticEvent) -> Void) {
        store.installTestSink(sink)
    }

    static func removeTestSink() {
        store.removeTestSink()
    }
}

private final class PasteBuddyDiagnosticsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var testSink: ((PasteBuddyDiagnosticEvent) -> Void)?

    func installTestSink(_ sink: @escaping (PasteBuddyDiagnosticEvent) -> Void) {
        lock.lock()
        testSink = sink
        lock.unlock()
    }

    func removeTestSink() {
        lock.lock()
        testSink = nil
        lock.unlock()
    }

    func emit(_ event: PasteBuddyDiagnosticEvent) {
        lock.lock()
        let sink = testSink
        lock.unlock()
        sink?(event)
    }
}
