import Foundation

@MainActor
enum ClipboardShelfDirectPasteCoordinator {
    private static let focusRestorationDelayNanoseconds: UInt64 = 300_000_000

    static func runAfterImmediateDismissal<T>(
        dismiss: () -> Void,
        operation: @MainActor () async -> T
    ) async -> T {
        PasteBuddyDiagnostics.record(.directPaste, "dismissImmediate")
        dismiss()
        await Task.yield()
        try? await Task.sleep(nanoseconds: focusRestorationDelayNanoseconds)
        PasteBuddyDiagnostics.record(.directPaste, "operationStarted")
        let result = await operation()
        PasteBuddyDiagnostics.record(.directPaste, "operationFinished")
        return result
    }
}
