import AppKit
import Foundation
import PasteBuddyCore
import SwiftUI
import UniformTypeIdentifiers

enum CopyConfirmationFeedbackMessage {
    static func text(
        itemCount: Int,
        localize: (String, String) -> String = PasteBuddyLocalization.string
    ) -> String {
        let singular = itemCount == 1
        let format = localize(
            singular ? "format.copied_item" : "format.copied_items",
            singular ? "Copied %d item" : "Copied %d items"
        )
        return String(format: format, locale: Locale.current, itemCount)
    }
}

struct CopyConfirmationFeedbackState {
    struct Presentation: Equatable {
        let generation: Int
        let itemCount: Int
    }

    private(set) var presentation: Presentation?
    private var generation = 0

    mutating func recordCopy(succeeded: Bool, itemCount: Int) -> Presentation? {
        guard succeeded, itemCount > 0 else { return nil }
        generation += 1
        let presentation = Presentation(generation: generation, itemCount: itemCount)
        self.presentation = presentation
        return presentation
    }

    mutating func dismiss(generation: Int) -> Bool {
        guard presentation?.generation == generation else { return false }
        presentation = nil
        return true
    }
}

@MainActor
final class CopyConfirmationFeedbackLifecycle {
    private(set) var state = CopyConfirmationFeedbackState()
    private var dismissalTask: Task<Void, Never>?

    @discardableResult
    func recordCopy(
        succeeded: Bool,
        itemCount: Int,
        dismissAfter duration: Duration,
        onDismiss: @escaping @MainActor () -> Void
    ) -> CopyConfirmationFeedbackState.Presentation? {
        guard let presentation = state.recordCopy(succeeded: succeeded, itemCount: itemCount) else {
            return nil
        }
        dismissalTask?.cancel()
        dismissalTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            guard let self, self.state.dismiss(generation: presentation.generation) else { return }
            onDismiss()
        }
        return presentation
    }
}

struct ClipboardNativeCopyFeedbackReceipt {
    static let pasteboardType = PasteboardWriter.internalCopyPasteboardType

    let data = Data(UUID().uuidString.utf8)

    @discardableResult
    func register(on provider: NSItemProvider) -> Bool {
        guard let validationType = Self.validationType(
            from: provider.registeredTypeIdentifiers
        ) else { return false }
        let providerBox = SendableItemProvider(provider)
        provider.registerDataRepresentation(
            forTypeIdentifier: Self.pasteboardType.rawValue,
            visibility: .all
        ) { completion in
            providerBox.value.loadDataRepresentation(forTypeIdentifier: validationType) { loadedData, error in
                if loadedData != nil, error == nil {
                    completion(data, nil)
                } else {
                    completion(nil, error ?? CocoaError(.fileReadNoSuchFile))
                }
            }
        }
        return true
    }

    func matches(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.data(forType: Self.pasteboardType) == data
    }

    private static func validationType(from identifiers: [String]) -> String? {
        let preferred = [
            UTType.utf8PlainText.identifier,
            UTType.plainText.identifier,
            UTType.fileURL.identifier,
            UTType.url.identifier,
            UTType.png.identifier,
            UTType.tiff.identifier,
        ]
        return preferred.first(where: identifiers.contains) ?? identifiers.first
    }
}

private final class SendableItemProvider: @unchecked Sendable {
    let value: NSItemProvider

    init(_ value: NSItemProvider) {
        self.value = value
    }
}

@MainActor
enum ClipboardPanelCopyCoordinator {
    static func itemProviders(
        for items: [ClipboardItem],
        sourceWindow: NSWindow?,
        hydrate: @escaping @MainActor (ClipboardItem) async -> ClipboardItem
    ) -> [NSItemProvider] {
        let providers = PasteboardWriter.itemProviders(for: items, hydrate: hydrate)
        guard let provider = providers.first else { return providers }
        let receipt = ClipboardNativeCopyFeedbackReceipt()
        guard receipt.register(on: provider) else { return providers }
        CopyConfirmationFeedbackController.shared.observeNativeCopy(
            receipt: receipt,
            itemCount: items.count,
            sourceWindow: sourceWindow
        )
        return providers
    }

    @discardableResult
    static func copy(
        _ item: ClipboardItem,
        format: PasteFormat = .original,
        to pasteboard: NSPasteboard = .general,
        sourceWindow: NSWindow? = nil,
        reportSuccess: ((Int) -> Void)? = nil
    ) -> Bool {
        let succeeded = PasteboardWriter.copy(item, format: format, to: pasteboard)
        if succeeded {
            if let reportSuccess {
                reportSuccess(1)
            } else {
                CopyConfirmationFeedbackController.shared.show(itemCount: 1, sourceWindow: sourceWindow)
            }
        }
        return succeeded
    }

    @discardableResult
    static func copy(
        _ items: [ClipboardItem],
        format: PasteFormat = .original,
        to pasteboard: NSPasteboard = .general,
        sourceWindow: NSWindow? = nil,
        reportSuccess: ((Int) -> Void)? = nil
    ) -> Bool {
        let succeeded = PasteboardWriter.copy(items, format: format, to: pasteboard)
        if succeeded {
            if let reportSuccess {
                reportSuccess(items.count)
            } else {
                CopyConfirmationFeedbackController.shared.show(
                    itemCount: items.count,
                    sourceWindow: sourceWindow
                )
            }
        }
        return succeeded
    }
}

@MainActor
final class CopyConfirmationFeedbackController {
    static let shared = CopyConfirmationFeedbackController()

    private static let displayDuration: Duration = .milliseconds(1_400)
    private static let nativeCopyObservationAttempts = 50
    private static let nativeCopyObservationInterval: Duration = .milliseconds(10)

    private let lifecycle = CopyConfirmationFeedbackLifecycle()
    private var panel: CopyConfirmationPanel?
    private var nativeCopyObservationTask: Task<Void, Never>?

    func show(itemCount: Int, sourceWindow: NSWindow?) {
        guard lifecycle.recordCopy(
            succeeded: true,
            itemCount: itemCount,
            dismissAfter: Self.displayDuration,
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        ) != nil else { return }
        let message = CopyConfirmationFeedbackMessage.text(itemCount: itemCount)
        let panel = feedbackPanel()
        let contentView = NSHostingView(rootView: CopyConfirmationFeedbackView(message: message))
        contentView.setFrameSize(contentView.fittingSize)
        panel.contentView = contentView
        panel.setContentSize(contentView.fittingSize)
        position(panel, on: sourceWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first)
        panel.sharingType = sourceWindow?.sharingType ?? .readOnly

        if panel.isVisible {
            panel.alphaValue = 1
        } else if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        announce(message, from: panel)
    }

    func observeNativeCopy(
        receipt: ClipboardNativeCopyFeedbackReceipt,
        itemCount: Int,
        sourceWindow: NSWindow?,
        pasteboard: NSPasteboard = .general
    ) {
        guard itemCount > 0 else { return }
        nativeCopyObservationTask?.cancel()
        nativeCopyObservationTask = Task { @MainActor [weak self] in
            for _ in 0..<Self.nativeCopyObservationAttempts {
                do {
                    try await Task.sleep(for: Self.nativeCopyObservationInterval)
                } catch {
                    return
                }
                guard receipt.matches(pasteboard) else { continue }
                self?.show(itemCount: itemCount, sourceWindow: sourceWindow)
                return
            }
        }
    }

    private func feedbackPanel() -> CopyConfirmationPanel {
        if let panel {
            return panel
        }
        let panel = CopyConfirmationPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("PasteBuddyCopyConfirmationHUD")
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel, on screen: NSScreen?) {
        guard let screen else { return }
        let visibleFrame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: (visibleFrame.midX - size.width / 2).rounded(),
            y: (visibleFrame.midY - size.height / 2).rounded()
        ))
    }

    private func dismiss() {
        panel?.orderOut(nil)
        panel?.alphaValue = 1
    }

    private func announce(_ message: String, from panel: NSPanel) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSNumber(value: NSAccessibilityPriorityLevel.medium.rawValue),
            ]
        )
    }
}

private struct CopyConfirmationFeedbackView: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(message)
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(.separator.opacity(0.45), lineWidth: 0.5)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

private final class CopyConfirmationPanel: NSPanel, PasteBuddyScreenSharingProtectedWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
