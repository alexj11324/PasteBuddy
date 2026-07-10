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
        let resolvedStore: PasteBuddyStore
        do {
            resolvedStore = try MobileStoreFactory.makeStore()
        } catch {
            showStoreLoadFailure(error.localizedDescription)
            return
        }
        Task { [weak self] in
            await resolvedStore.loadAsync()
            guard let self else { return }
            guard !resolvedStore.isPersistenceWriteBlocked else {
                showStoreLoadFailure(
                    resolvedStore.lastErrorMessage
                        ?? PasteBuddyLocalization.string(
                            "mobile.error.history_load_failed",
                            defaultValue: "PasteBuddy could not load encrypted history."
                        )
                )
                return
            }
            finishConfiguringKeyboard(with: resolvedStore)
        }
    }

    private func showStoreLoadFailure(_ message: String) {
        let label = UILabel()
        label.text = message
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func finishConfiguringKeyboard(with resolvedStore: PasteBuddyStore) {
        resolvedStore.setKeyboardExtensionEnabled(true, fullAccess: hasFullAccess)
        Task { @MainActor in
            _ = await resolvedStore.flushPendingSave()
        }
        store = resolvedStore

        let syncService = MobileStoreFactory.makeIrohSyncService()
        syncService.onItemReceived = { [resolvedStore, weak syncService] item in
            guard !resolvedStore.isPersistenceWriteBlocked else { return }
            _ = resolvedStore.addSyncedItem(item)
            do {
                try await resolvedStore.flushPendingSaveOrThrow()
            } catch {
                syncService?.reportReceivePersistenceFailure(error)
            }
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
        if let store {
            Task { @MainActor in
                _ = await store.flushPendingSave()
            }
        }
        startSyncIfAllowed()
    }

    private func startSyncIfAllowed() {
        guard hasFullAccess, let irohSync else { return }
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
