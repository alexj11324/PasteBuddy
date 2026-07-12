import Foundation
import OSLog
import PasteBuddyCore

enum PasteBuddyDiagnosticCategory: String, Sendable {
    case lifecycle
    case hotKey
    case shelf
    case directPaste
}

struct PasteBuddyDiagnosticEvent: Equatable, Sendable {
    var category: PasteBuddyDiagnosticCategory
    var name: String
    var detail: String?
}

struct PasteBuddyCardSwitchLatencyMeasurement: Equatable, Sendable {
    var probeID: UInt64
    var recognitionMilliseconds: Double
    var applyMilliseconds: Double
    var totalMilliseconds: Double
}

@MainActor
final class PasteBuddyCardSwitchLatencyTracker {
    static let shared = PasteBuddyCardSwitchLatencyTracker()

    private struct PendingProbe {
        var id: UInt64
        var pointerDownNanoseconds: UInt64
        var recognizedNanoseconds: UInt64?
        var itemID: UUID?
    }

    private var nextProbeID: UInt64 = 0
    private var pendingProbe: PendingProbe?

    @discardableResult
    func recordPointerDown(
        atUptimeNanoseconds now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> UInt64 {
        nextProbeID &+= 1
        let probeID = nextProbeID
        pendingProbe = PendingProbe(
            id: probeID,
            pointerDownNanoseconds: now,
            recognizedNanoseconds: nil,
            itemID: nil
        )
        PasteBuddyDiagnostics.record(.shelf, "cardSwitchStarted", detail: "probe=\(probeID)")
        return probeID
    }

    @discardableResult
    func recordSelectionRecognized(
        itemID: UUID,
        atUptimeNanoseconds now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> UInt64? {
        guard var probe = pendingProbe else { return nil }
        probe.recognizedNanoseconds = now
        probe.itemID = itemID
        pendingProbe = probe
        return probe.id
    }

    @discardableResult
    func recordSelectionApplied(
        itemID: UUID,
        atUptimeNanoseconds now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> PasteBuddyCardSwitchLatencyMeasurement? {
        guard let probe = pendingProbe,
              probe.itemID == itemID,
              let recognizedNanoseconds = probe.recognizedNanoseconds,
              now >= recognizedNanoseconds,
              recognizedNanoseconds >= probe.pointerDownNanoseconds else {
            return nil
        }
        pendingProbe = nil
        let measurement = PasteBuddyCardSwitchLatencyMeasurement(
            probeID: probe.id,
            recognitionMilliseconds: Self.milliseconds(
                recognizedNanoseconds - probe.pointerDownNanoseconds
            ),
            applyMilliseconds: Self.milliseconds(now - recognizedNanoseconds),
            totalMilliseconds: Self.milliseconds(now - probe.pointerDownNanoseconds)
        )
        PasteBuddyDiagnostics.record(
            .shelf,
            "cardSwitchCompleted",
            detail: String(
                format: "probe=%llu recognitionMs=%.3f applyMs=%.3f totalMs=%.3f",
                measurement.probeID,
                measurement.recognitionMilliseconds,
                measurement.applyMilliseconds,
                measurement.totalMilliseconds
            )
        )
        return measurement
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }
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
