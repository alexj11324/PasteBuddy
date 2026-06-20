import PasteBuddyCore
import SwiftUI

struct ContentView: View {
    @Bindable var store: PasteBuddyStore
    let directPasteItem: @MainActor (ClipboardItem, PasteFormat) async -> DirectPasteResult
    let directPasteItems: @MainActor ([ClipboardItem], PasteFormat) async -> DirectPasteResult
    let currentExternalApplication: () -> ExternalApplicationIdentity?
    @Binding var isShowingNewTextItem: Bool

    init(
        store: PasteBuddyStore,
        directPasteItem: @escaping @MainActor (ClipboardItem, PasteFormat) async -> DirectPasteResult,
        directPasteItems: @escaping @MainActor ([ClipboardItem], PasteFormat) async -> DirectPasteResult,
        isShowingNewTextItem: Binding<Bool> = .constant(false),
        currentExternalApplication: @escaping () -> ExternalApplicationIdentity? = { nil }
    ) {
        self.store = store
        self.directPasteItem = directPasteItem
        self.directPasteItems = directPasteItems
        self._isShowingNewTextItem = isShowingNewTextItem
        self.currentExternalApplication = currentExternalApplication
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                store: store,
                currentExternalApplication: currentExternalApplication
            )
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } content: {
            ItemListView(
                store: store,
                directPasteItem: directPasteItem,
                directPasteItems: directPasteItems
            )
                .navigationSplitViewColumnWidth(min: 360, ideal: 460)
        } detail: {
            ItemDetailView(store: store, directPasteItem: directPasteItem)
        }
        .searchable(text: $store.searchQuery, placement: .toolbar, prompt: "Search clipboard")
        .searchSuggestions {
            ForEach(store.filterSuggestions) { suggestion in
                Button {
                    store.applyFilterSuggestion(suggestion)
                } label: {
                    Label(suggestion.title, systemImage: suggestion.systemImageName)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.toggleCapturePaused()
                } label: {
                    Label(captureActionTitle, systemImage: store.isCapturePaused ? "play.fill" : "pause.fill")
                }

                Button {
                    store.createPinboard()
                } label: {
                    Label("label.new_pinboard", systemImage: "plus.circle")
                }

                Button {
                    isShowingNewTextItem = true
                } label: {
                    Label("label.new_text_item", systemImage: "square.and.pencil")
                }

                Button {
                    store.undoLastDeletion()
                } label: {
                    Label("action.undo_delete", systemImage: "arrow.uturn.backward")
                }
                .disabled(!store.canUndoDelete)
            }
        }
        .sheet(isPresented: $isShowingNewTextItem) {
            NewTextItemSheet { title, text in
                guard store.createTextItem(text: text, title: title) != nil else {
                    return store.lastErrorMessage ?? NSLocalizedString("message.pastebuddy_could_not_create_this_item", comment: "")
                }
                isShowingNewTextItem = false
                return nil
            } onCancel: {
                isShowingNewTextItem = false
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if store.privacyPostureReport.captureStatus.isPaused {
                    PrivacyCaptureStatusBar(report: store.privacyPostureReport) {
                        store.resumeCapture()
                    }
                }

                if let result = store.lastDirectPasteResult {
                    DirectPasteStatusBar(result: result) {
                        store.clearDirectPasteResult()
                    }
                }
            }
        }
    }

    private var captureActionTitle: String {
        NSLocalizedString(store.isCapturePaused ? "action.resume_capture" : "action.pause_capture", comment: "")
    }
}

private struct PrivacyCaptureStatusBar: View {
    let report: PrivacyPostureReport
    let onResume: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text(report.captureStatus.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button("action.resume") {
                onResume()
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(report.captureStatus.displayName)
    }

    private var statusDetail: String {
        switch report.captureStatus {
        case .active:
            report.captureStatus.detail
        case .pausedIndefinitely:
            report.captureStatus.detail
        case .pausedUntil(let date):
            "\(report.captureStatus.detail) \(String(format: NSLocalizedString("format.resumes_at", comment: ""), date.formatted(date: .omitted, time: .shortened)))"
        }
    }
}

private struct DirectPasteStatusBar: View {
    let result: DirectPasteResult
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: resultIconName)
                .foregroundStyle(result.needsAccessibilityPermission ? .orange : .secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(result.statusMessage)
                    .font(.callout)
                    .lineLimit(2)

                if let guidance = result.permissionGuidance {
                    Text(guidance.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            Spacer()

            if let guidance = result.permissionGuidance {
                Button(guidance.actionTitle) {
                    AccessibilityPermissionService.requestTrustPrompt()
                }
                .buttonStyle(.borderless)
            }

            Button("action.dismiss") {
                onDismiss()
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(result.statusMessage)
    }

    private var resultIconName: String {
        switch result.outcome {
        case .pastedToFrontmostApp:
            "checkmark.circle.fill"
        case .failedAccessibilityPermissionRequired:
            "exclamationmark.triangle.fill"
        case .failedNoTargetApplication:
            "arrowshape.turn.up.left.circle.fill"
        case .copiedOnlyAccessibilityRequired:
            "exclamationmark.triangle.fill"
        case .copiedOnlyNoTargetApplication:
            "arrowshape.turn.up.left.circle.fill"
        case .emptySelection:
            "info.circle.fill"
        }
    }
}

struct NewTextItemSheet: View {
    @State private var title = ""
    @State private var text = ""
    @State private var errorMessage: String?
    let onSave: (String?, String) -> String?
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("label.new_text_item")
                .font(.headline)

            TextField("label.title", text: $title)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 180)
                .border(.quaternary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("action.cancel", role: .cancel) {
                    onCancel()
                }
                Button("action.create") {
                    errorMessage = onSave(title, text)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
