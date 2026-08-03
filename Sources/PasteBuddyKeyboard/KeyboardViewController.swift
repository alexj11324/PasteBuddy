import PasteBuddyCore
import PasteBuddyMobile
import SwiftUI
import UIKit

@MainActor
final class KeyboardViewController: UIInputViewController {
    private var store: PasteBuddyStore?
    private var irohSync: IrohClipboardSyncService?
    private var hostingController: UIHostingController<MobileKeyboardHistoryView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureKeyboard()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshFullAccessState()
    }

    private func configureKeyboard() {
        let resolvedStore = MobileStoreFactory.makeStore()
        resolvedStore.load()
        resolvedStore.setKeyboardExtensionEnabled(true, fullAccess: hasFullAccess)
        store = resolvedStore

        let syncService = PasteBuddyFeatureAvailability.irohClipboardSync
            ? MobileStoreFactory.makeIrohSyncService()
            : nil
        syncService?.onItemReceived = { [resolvedStore] item in
            _ = resolvedStore.addSyncedItem(item)
        }
        irohSync = syncService

        let pasteService = MobileKeyboardPasteService { [weak self] text in
            guard let self else { return false }
            textDocumentProxy.insertText(text)
            return true
        }
        let rootView = MobileKeyboardHistoryView(
            store: resolvedStore,
            pasteService: pasteService,
            irohSync: syncService,
            onDeleteBackward: { [weak self] in
                self?.textDocumentProxy.deleteBackward()
            },
            onInsertReturn: { [weak self] in
                self?.textDocumentProxy.insertText("\n")
            },
            onAdvanceToNextInputMode: { [weak self] in
                self?.advanceToNextInputMode()
            }
        )
        let host = UIHostingController(rootView: rootView)
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 320)
        ])
        host.didMove(toParent: self)
        hostingController = host
        startSyncIfAllowed()
    }

    private func refreshFullAccessState() {
        store?.setKeyboardExtensionEnabled(true, fullAccess: hasFullAccess)
        startSyncIfAllowed()
    }

    private func startSyncIfAllowed() {
        guard PasteBuddyFeatureAvailability.irohClipboardSync,
              hasFullAccess,
              let irohSync else { return }
        switch irohSync.connectionState {
        case .connecting, .connected:
            return
        case .idle, .binding, .ready, .failed:
            Task { @MainActor in
                await irohSync.start()
                guard !irohSync.peerEndpointId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }
                await irohSync.connectToPeer()
            }
        }
    }
}
