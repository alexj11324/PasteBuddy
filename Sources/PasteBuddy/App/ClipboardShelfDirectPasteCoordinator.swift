import Foundation

@MainActor
enum ClipboardPanelPasteGate {
    struct Request {
        let generation: Int
    }

    private static var generation = 0

    static func begin() -> Request {
        generation += 1
        return Request(generation: generation)
    }

    static func shouldPaste(_ request: Request) -> Bool {
        request.generation == generation
    }
}

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
            await Task.yield()
        }
        PasteBuddyDiagnostics.record(.directPaste, "operationStarted")
        let result = await operation()
        PasteBuddyDiagnostics.record(.directPaste, "operationFinished")
        return result
    }
}
