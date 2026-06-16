import Foundation

@MainActor
enum ClipboardShelfDirectPasteCoordinator {
    static func runAfterImmediateDismissal<T>(
        dismiss: () -> Void,
        operation: @MainActor () async -> T
    ) async -> T {
        PasteBuddyDiagnostics.record(.directPaste, "dismissImmediate")
        dismiss()
        await Task.yield()
        PasteBuddyDiagnostics.record(.directPaste, "operationStarted")
        let result = await operation()
        PasteBuddyDiagnostics.record(.directPaste, "operationFinished")
        return result
    }
}
