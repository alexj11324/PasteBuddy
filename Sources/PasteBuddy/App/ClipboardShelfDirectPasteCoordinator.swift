import Foundation

@MainActor
enum ClipboardShelfDirectPasteCoordinator {
    static func runAfterImmediateDismissal<T>(
        dismissBeforePaste: Bool = true,
        dismiss: () -> Void,
        operation: @MainActor () async -> T
    ) async -> T {
        if dismissBeforePaste {
            PasteBuddyDiagnostics.record(.directPaste, "dismissImmediate")
            dismiss()
            await Task.yield()
        } else {
            PasteBuddyDiagnostics.record(.directPaste, "dismissSkipped")
        }
        PasteBuddyDiagnostics.record(.directPaste, "operationStarted")
        let result = await operation()
        PasteBuddyDiagnostics.record(.directPaste, "operationFinished")
        return result
    }
}
