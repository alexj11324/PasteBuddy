import AppKit
import Observation
import PasteBuddyCore
import SwiftUI
import UniformTypeIdentifiers

enum ScreenPinAction {
    case close
    case destroy
    case toggleLock
    case toggleAlwaysOnTop
    case toggleClickThrough
    case toggleThumbnail
    case resetAppearance
    case rename
    case copy
    case copyText(String, sourceKey: String)
    case pinText(String)
    case save
    case recognize
    case translate
}

@MainActor
@Observable
final class ScreenPinViewModel {
    var item: ClipboardItem
    var state: ScreenPinState
    var ocrAnalysis: OCRAnalysis?
    var translation: NativeTranslationResult?
    var errorMessage: String?
    var isWorking = false
    @ObservationIgnored var onAction: (ScreenPinAction) -> Void

    init(
        item: ClipboardItem,
        state: ScreenPinState,
        onAction: @escaping (ScreenPinAction) -> Void
    ) {
        self.item = item
        self.state = state
        self.onAction = onAction
    }
}

@MainActor
final class ScreenPinController {
    static let shared = ScreenPinController()

    private enum PersistenceKey {
        static let groups = "PasteBuddyScreenPinGroups"
        static let activeGroupID = "PasteBuddyScreenPinActiveGroupID"
        static let recent = "PasteBuddyScreenPinRecentlyClosed"
    }

    private var store: PasteBuddyStore?
    private var registry: ScreenPinRegistry
    private var panels: [UUID: ScreenPinPanel] = [:]
    private var models: [UUID: ScreenPinViewModel] = [:]
    private let translationService = NativeTranslationService()

    private init() {
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        let groups = defaults.data(forKey: PersistenceKey.groups)
            .flatMap { try? decoder.decode([ScreenPinGroup].self, from: $0) }
        let activeGroupID = defaults.string(forKey: PersistenceKey.activeGroupID)
            .flatMap(UUID.init(uuidString:))
        registry = ScreenPinRegistry(
            groups: groups,
            activeGroupID: activeGroupID,
            defaultGroupName: NSLocalizedString("label.default_pin_group", comment: "")
        )
        if let recentData = defaults.data(forKey: PersistenceKey.recent),
           let recent = try? decoder.decode([ScreenPinState].self, from: recentData) {
            for state in recent.reversed() {
                registry.add(state)
                _ = registry.close(id: state.id, at: state.closedAt ?? Date())
            }
        }
    }

    func configure(store: PasteBuddyStore) {
        self.store = store
    }

    var visiblePinCount: Int {
        panels.values.filter(\.isVisible).count
    }

    var hasRecoverableClickThroughPins: Bool {
        registry.activePins.contains(where: \.isClickThrough)
    }

    var groups: [ScreenPinGroup] {
        registry.groups
    }

    var activeGroupID: UUID {
        registry.activeGroupID
    }

    func pinClipboard() {
        guard let store,
              let item = ClipboardMonitor.makeItem(
                  from: .general,
                  sourceApp: NSWorkspace.shared.frontmostApplication?.localizedName
                      ?? NSLocalizedString("automation.destination.clipboard", comment: ""),
                  sourceBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                  privacy: store.snapshot.privacy
              ) else {
            showError(NSLocalizedString("message.the_clipboard_does_not_contain_supported_image", comment: ""))
            return
        }
        let stored = store.addCapturedItem(item)
        pin(stored)
    }

    func pin(_ item: ClipboardItem, preferredFrame: CGRect? = nil) {
        let kind = ScreenPinKind.resolve(item: item)
        let frame = preferredFrame ?? initialFrame(for: item, kind: kind)
        let state = ScreenPinState(
            itemID: item.id,
            kind: kind,
            title: item.title,
            frame: frame,
            groupID: registry.activeGroupID
        )
        registry.add(state)
        present(item: item, state: state)
        persist()
        PasteBuddyDiagnostics.record(
            .pin,
            "created",
            detail: "id=\(state.id) kind=\(kind.rawValue) group=\(state.groupID)"
        )
    }

    func restoreMostRecent() {
        guard let store,
              let candidate = registry.recentlyClosed.first,
              let item = store.snapshot.items.first(where: { $0.id == candidate.itemID }),
              let restored = registry.restoreMostRecent() else {
            showError(NSLocalizedString("message.the_recently_closed_pin_can_no_longer", comment: ""))
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let hydrated = await store.hydratedItem(for: item)
            self.present(item: hydrated, state: restored)
            self.persist()
        }
    }

    func showAll() {
        for state in registry.activePins where state.groupID == registry.activeGroupID {
            panels[state.id]?.orderFrontRegardless()
        }
    }

    func hideAll() {
        panels.values.forEach { $0.orderOut(nil) }
    }

    func closeAll() {
        for id in Array(panels.keys) {
            close(id: id)
        }
    }

    func disableClickThroughOnAllPins() {
        for state in registry.activePins where state.isClickThrough {
            guard var updated = registry.activePins.first(where: { $0.id == state.id }) else {
                continue
            }
            updated.isClickThrough = false
            apply(updated)
        }
    }

    func saveAll() {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("dialog.save_all_pins", comment: "")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        for state in registry.activePins {
            guard let model = models[state.id] else { continue }
            do {
                try save(model.item, title: state.title, to: directory)
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    func createGroup(name: String, colorHex: String? = nil) -> ScreenPinGroup? {
        let group = registry.createGroup(name: name, colorHex: colorHex)
        if group != nil {
            persist()
        }
        return group
    }

    func selectGroup(_ id: UUID) {
        guard registry.selectGroup(id) else { return }
        for state in registry.activePins {
            if state.groupID == id {
                panels[state.id]?.orderFrontRegardless()
            } else {
                panels[state.id]?.orderOut(nil)
            }
        }
        persist()
    }

    private func present(item: ClipboardItem, state: ScreenPinState) {
        let model = ScreenPinViewModel(item: item, state: state) { [weak self] action in
            self?.perform(action, pinID: state.id)
        }
        let panel = ScreenPinPanel(
            contentRect: state.frame,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = state.title
        panel.setAccessibilityLabel(state.title)
        panel.level = state.isAlwaysOnTop ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = state.isAlwaysOnTop
        panel.isMovableByWindowBackground = !state.isLocked
        if state.isLocked {
            panel.styleMask.remove(.resizable)
        }
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.alphaValue = state.opacity
        panel.ignoresMouseEvents = state.isClickThrough
        panel.minSize = NSSize(width: 120, height: 80)
        panel.maxSize = NSSize(width: 2_400, height: 2_400)
        panel.onClose = { [weak self] in self?.close(id: state.id) }
        let content = ScreenPinContentView(model: model)
        let hosting = ScreenPinHostingView(rootView: content)
        hosting.pinID = state.id
        hosting.onKeyAction = { [weak self] action in
            self?.perform(action, pinID: state.id)
        }
        hosting.onNudge = { [weak self] dx, dy in
            self?.nudge(id: state.id, dx: dx, dy: dy)
        }
        hosting.onScroll = { [weak self] delta, modifiers in
            self?.handleScroll(id: state.id, delta: delta, modifiers: modifiers)
        }
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 12
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = false
        panel.contentView = hosting
        panel.observerTokens.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self, weak panel] in
                guard let panel else { return }
                self?.recordFrame(panel.frame, id: state.id)
            }
        })
        panel.observerTokens.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self, weak panel] in
                guard let panel else { return }
                self?.recordFrame(panel.frame, id: state.id)
            }
        })
        panels[state.id] = panel
        models[state.id] = model
        panel.orderFrontRegardless()
    }

    private func perform(_ action: ScreenPinAction, pinID: UUID) {
        guard let model = models[pinID] else { return }
        switch action {
        case .close:
            close(id: pinID)
        case .destroy:
            destroy(id: pinID)
        case .toggleLock:
            var state = model.state
            state.isLocked.toggle()
            apply(state)
        case .toggleAlwaysOnTop:
            var state = model.state
            state.isAlwaysOnTop.toggle()
            apply(state)
        case .toggleClickThrough:
            var state = model.state
            state.isClickThrough.toggle()
            apply(state)
        case .toggleThumbnail:
            var state = model.state
            state.isThumbnail.toggle()
            apply(state)
        case .resetAppearance:
            var state = model.state
            state.opacity = 1
            state.isThumbnail = false
            state.cropRect = nil
            apply(state)
            panels[pinID]?.setFrame(initialFrame(for: model.item, kind: state.kind), display: true)
        case .rename:
            rename(id: pinID)
        case .copy:
            ClipboardPanelCopyCoordinator.copy(
                model.item,
                sourceWindow: panels[pinID]
            )
        case .copyText(let text, let sourceKey):
            ClipboardPanelCopyCoordinator.copy(
                textItem(text, sourceKey: sourceKey),
                sourceWindow: panels[pinID]
            )
        case .pinText(let text):
            guard let stored = store?.addCapturedItem(
                textItem(text, sourceKey: "source.pastebuddy_translation")
            ) else {
                return
            }
            pin(stored)
        case .save:
            saveOne(id: pinID)
        case .recognize:
            recognize(id: pinID)
        case .translate:
            translate(id: pinID)
        }
    }

    private func apply(_ state: ScreenPinState) {
        registry.update(state)
        models[state.id]?.state = state
        guard let panel = panels[state.id] else { return }
        panel.level = state.isAlwaysOnTop ? .floating : .normal
        panel.isFloatingPanel = state.isAlwaysOnTop
        panel.alphaValue = state.opacity
        panel.ignoresMouseEvents = state.isClickThrough
        panel.isMovableByWindowBackground = !state.isLocked
        if state.isLocked {
            panel.styleMask.remove(.resizable)
        } else {
            panel.styleMask.insert(.resizable)
        }
        panel.hasShadow = !state.isClickThrough
        persist()
    }

    private func close(id: UUID) {
        guard registry.close(id: id) != nil else { return }
        let panel = panels.removeValue(forKey: id)
        panel?.observerTokens.forEach(NotificationCenter.default.removeObserver)
        panel?.observerTokens.removeAll()
        panel?.orderOut(nil)
        models.removeValue(forKey: id)
        persist()
        PasteBuddyDiagnostics.record(.pin, "closed", detail: "id=\(id)")
    }

    private func destroy(id: UUID) {
        registry.destroy(id: id)
        let panel = panels.removeValue(forKey: id)
        panel?.observerTokens.forEach(NotificationCenter.default.removeObserver)
        panel?.observerTokens.removeAll()
        panel?.close()
        models.removeValue(forKey: id)
        persist()
        PasteBuddyDiagnostics.record(.pin, "destroyed", detail: "id=\(id)")
    }

    private func nudge(id: UUID, dx: CGFloat, dy: CGFloat) {
        guard let model = models[id], !model.state.isLocked, let panel = panels[id] else {
            return
        }
        panel.setFrameOrigin(CGPoint(x: panel.frame.minX + dx, y: panel.frame.minY + dy))
    }

    private func handleScroll(
        id: UUID,
        delta: CGFloat,
        modifiers: NSEvent.ModifierFlags
    ) {
        guard let model = models[id], !model.state.isLocked, let panel = panels[id] else {
            return
        }
        if modifiers.contains(.control) || modifiers.contains(.option) {
            var state = model.state
            state.opacity = min(max(state.opacity + Double(delta) * 0.02, 0.1), 1)
            apply(state)
            return
        }
        let factor = min(max(1 + delta * 0.025, 0.8), 1.2)
        let oldFrame = panel.frame
        let newSize = CGSize(
            width: min(max(oldFrame.width * factor, panel.minSize.width), panel.maxSize.width),
            height: min(max(oldFrame.height * factor, panel.minSize.height), panel.maxSize.height)
        )
        panel.setFrame(
            CGRect(
                x: oldFrame.midX - newSize.width / 2,
                y: oldFrame.midY - newSize.height / 2,
                width: newSize.width,
                height: newSize.height
            ),
            display: true
        )
    }

    private func recordFrame(_ frame: CGRect, id: UUID) {
        guard var state = registry.activePins.first(where: { $0.id == id }) else { return }
        state.frame = frame
        registry.update(state)
        models[id]?.state = state
        persist()
    }

    private func rename(id: UUID) {
        guard var state = registry.activePins.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("dialog.rename_pin", comment: "")
        let field = NSTextField(string: state.title)
        field.frame.size = CGSize(width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: NSLocalizedString("action.save", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("action.cancel", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        state.title = title
        panels[id]?.title = title
        panels[id]?.setAccessibilityLabel(title)
        apply(state)
    }

    private func recognize(id: UUID) {
        guard let model = models[id] else { return }
        Task { @MainActor [weak self, weak model] in
            guard let self, let model else { return }
            model.isWorking = true
            defer { model.isWorking = false }
            let data: Data?
            if let imageData = model.item.payload.imageData {
                data = imageData
            } else {
                data = await self.store?.imageData(for: model.item)
            }
            guard let data else {
                model.errorMessage = NSLocalizedString("message.text_recognition_requires_an_image_pin", comment: "")
                return
            }
            do {
                let analysis = try await OCRService().analyze(in: data)
                model.ocrAnalysis = analysis
                if !analysis.transcript.isEmpty {
                    self.store?.updateOCRText(analysis.transcript, for: model.item.id)
                }
                PasteBuddyDiagnostics.record(
                    .pin,
                    "ocrCompleted",
                    detail: "id=\(id) lines=\(analysis.textObservations.count) barcodes=\(analysis.barcodes.count)"
                )
            } catch {
                model.errorMessage = error.localizedDescription
                PasteBuddyDiagnostics.record(.pin, "ocrFailed", detail: "id=\(id) error=\(error.localizedDescription)")
            }
        }
    }

    private func translate(id: UUID) {
        guard let model = models[id] else { return }
        let text = model.ocrAnalysis?.transcript.nilIfEmpty
            ?? model.item.payload.ocrText?.nilIfEmpty
            ?? model.item.payload.primaryText.nilIfEmpty
        guard let text else {
            model.errorMessage = NSLocalizedString("message.there_is_no_text_to_translate", comment: "")
            return
        }
        let target = UserDefaults.standard.string(forKey: "PasteBuddyTranslationTargetLanguage")
            ?? defaultTranslationTarget()
        Task { @MainActor [weak self, weak model] in
            guard let self, let model else { return }
            model.isWorking = true
            defer { model.isWorking = false }
            do {
                model.translation = try await self.translationService.translate(
                    text,
                    targetLanguageIdentifier: target
                )
                PasteBuddyDiagnostics.record(.pin, "translationCompleted", detail: "id=\(id) target=\(target)")
            } catch {
                model.errorMessage = error.localizedDescription
                PasteBuddyDiagnostics.record(.pin, "translationFailed", detail: "id=\(id) error=\(error.localizedDescription)")
            }
        }
    }

    private func saveOne(id: UUID) {
        guard let model = models[id] else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            try save(model.item, title: model.state.title, to: directory)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func textItem(_ text: String, sourceKey: String) -> ClipboardItem {
        ClipboardItem(
            sourceAppName: NSLocalizedString(sourceKey, comment: ""),
            sourceBundleIdentifier: Bundle.main.bundleIdentifier,
            deviceName: Host.current().localizedName
                ?? NSLocalizedString("label.this_mac", comment: ""),
            contentType: .text,
            title: text.singleLinePreview,
            payload: ClipboardPayload(text: text)
        )
    }

    private func save(_ item: ClipboardItem, title: String, to directory: URL) throws {
        let safeTitle = title
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? NSLocalizedString("label.pastebuddy_pin", comment: "")
        if ScreenPinKind.resolve(item: item) == .files {
            for value in item.payload.allFileURLStrings {
                guard let source = URL(string: value), source.isFileURL else { continue }
                let destination = availableURL(
                    in: directory,
                    title: source.deletingPathExtension().lastPathComponent,
                    extension: source.pathExtension
                )
                try FileManager.default.copyItem(at: source, to: destination)
            }
            return
        }
        if let data = item.payload.imageData {
            try data.write(
                to: availableURL(in: directory, title: safeTitle, extension: "png"),
                options: .atomic
            )
            return
        }
        let text = item.payload.primaryText
        try Data(text.utf8).write(
            to: availableURL(
                in: directory,
                title: safeTitle,
                extension: ScreenPinKind.resolve(item: item) == .latex ? "tex" : "txt"
            ),
            options: .atomic
        )
    }

    private func availableURL(in directory: URL, title: String, extension: String) -> URL {
        let initial = directory.appendingPathComponent(title).appendingPathExtension(`extension`)
        guard FileManager.default.fileExists(atPath: initial.path) else { return initial }
        for index in 2...10_000 {
            let candidate = directory
                .appendingPathComponent("\(title) \(index)")
                .appendingPathExtension(`extension`)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory
            .appendingPathComponent("\(title) \(UUID().uuidString)")
            .appendingPathExtension(`extension`)
    }

    private func initialFrame(for item: ClipboardItem, kind: ScreenPinKind) -> CGRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let size: CGSize
        if kind == .image,
           let imageData = item.payload.imageData,
           let image = NSImage(data: imageData) {
            let ratio = image.size.width / max(image.size.height, 1)
            size = CGSize(
                width: min(max(image.size.width, 220), 720),
                height: min(max(320 / max(ratio, 0.25), 140), 600)
            )
        } else {
            size = CGSize(width: 360, height: 240)
        }
        let visible = screen.visibleFrame
        return CGRect(
            x: min(max(mouse.x - size.width / 2, visible.minX), visible.maxX - size.width),
            y: min(max(mouse.y - size.height / 2, visible.minY), visible.maxY - size.height),
            width: size.width,
            height: size.height
        )
    }

    private func defaultTranslationTarget() -> String {
        let current = Locale.current.language.languageCode?.identifier ?? "en"
        return current == "zh" ? "zh-Hans" : current
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.runModal()
    }

    private func persist() {
        let encoder = JSONEncoder()
        let defaults = UserDefaults.standard
        defaults.set(try? encoder.encode(registry.groups), forKey: PersistenceKey.groups)
        defaults.set(registry.activeGroupID.uuidString, forKey: PersistenceKey.activeGroupID)
        defaults.set(try? encoder.encode(registry.recentlyClosed), forKey: PersistenceKey.recent)
    }
}

private final class ScreenPinPanel: NSPanel {
    var onClose: (() -> Void)?
    var observerTokens: [NSObjectProtocol] = []

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

}

private final class ScreenPinHostingView<Content: View>: NSHostingView<Content> {
    var pinID: UUID?
    var onKeyAction: ((ScreenPinAction) -> Void)?
    var onNudge: ((CGFloat, CGFloat) -> Void)?
    var onScroll: ((CGFloat, NSEvent.ModifierFlags) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event.scrollingDeltaY, event.modifierFlags)
    }

    override func keyDown(with event: NSEvent) {
        let amount: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123:
            onNudge?(-amount, 0)
        case 124:
            onNudge?(amount, 0)
        case 125:
            onNudge?(0, -amount)
        case 126:
            onNudge?(0, amount)
        case 37:
            onKeyAction?(.toggleLock)
        case 17:
            onKeyAction?(.toggleAlwaysOnTop)
        case 15:
            onKeyAction?(.toggleThumbnail)
        case 120:
            onKeyAction?(.rename)
        case 53:
            onKeyAction?(.close)
        case 2 where event.modifierFlags.contains(.command):
            onKeyAction?(.destroy)
        default:
            super.keyDown(with: event)
        }
    }
}

private struct ScreenPinContentView: View {
    @Bindable var model: ScreenPinViewModel

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let analysis = model.ocrAnalysis {
                recognitionResult(analysis)
            }
            if let translation = model.translation {
                translationResult(translation)
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
            }
            HStack(spacing: 8) {
                Text(model.state.title)
                    .lineLimit(1)
                    .font(.caption.weight(.semibold))
                Spacer()
                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    model.onAction(.recognize)
                } label: {
                    Image(systemName: "text.viewfinder")
                }
                .buttonStyle(.plain)
                .disabled(model.state.kind != .image)
                .help(NSLocalizedString("action.recognize_text", comment: ""))
                .accessibilityLabel(Text("action.recognize_text"))
                Button {
                    model.onAction(.translate)
                } label: {
                    Image(systemName: "character.bubble")
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("action.translate", comment: ""))
                .accessibilityLabel(Text("action.translate"))
                Menu {
                    menu
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(Text("action.more"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.18))
        }
        .contextMenu {
            menu
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.state.title)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state.kind {
        case .image:
            if let data = model.item.payload.imageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: model.state.isThumbnail ? .fill : .fit)
                    .clipped()
                    .onDrag { NSItemProvider(object: image) }
            } else {
                ContentUnavailableView(
                    NSLocalizedString("message.the_pinned_image_is_unavailable", comment: ""),
                    systemImage: "photo"
                )
            }
        case .files:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.item.payload.allFileURLStrings, id: \.self) { value in
                        if let url = URL(string: value) {
                            Label(url.lastPathComponent, systemImage: "doc")
                                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .color:
            let color = ScreenPinColor.parse(model.item.payload.primaryText)
            VStack(spacing: 10) {
                Color(nsColor: color?.nsColor ?? .clear)
                Text(color?.hexString ?? model.item.payload.primaryText)
                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                    .textSelection(.enabled)
            }
            .padding()
            .onDrag {
                NSItemProvider(object: (color?.hexString ?? model.item.payload.primaryText) as NSString)
            }
        case .latex:
            ScrollView {
                Text(model.item.payload.primaryText)
                    .font(.system(.body, design: .serif))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onDrag { NSItemProvider(object: model.item.payload.primaryText as NSString) }
        case .text:
            ScrollView {
                Text(model.item.payload.primaryText)
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onDrag { NSItemProvider(object: model.item.payload.primaryText as NSString) }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button(NSLocalizedString("action.copy", comment: "")) {
            model.onAction(.copy)
        }
        Button(NSLocalizedString("action.save", comment: "")) {
            model.onAction(.save)
        }
        Button(NSLocalizedString("action.rename", comment: "")) {
            model.onAction(.rename)
        }
        Divider()
        Button(
            NSLocalizedString(
                model.state.isLocked ? "action.unlock_pin" : "action.lock_pin",
                comment: ""
            )
        ) {
            model.onAction(.toggleLock)
        }
        Button(
            NSLocalizedString(
                model.state.isAlwaysOnTop ? "action.disable_always_on_top" : "action.enable_always_on_top",
                comment: ""
            )
        ) {
            model.onAction(.toggleAlwaysOnTop)
        }
        Button(
            NSLocalizedString(
                model.state.isClickThrough ? "action.disable_click_through" : "action.enable_click_through",
                comment: ""
            )
        ) {
            model.onAction(.toggleClickThrough)
        }
        if model.state.kind == .image {
            Button(NSLocalizedString("action.toggle_thumbnail_crop", comment: "")) {
                model.onAction(.toggleThumbnail)
            }
        }
        Button(NSLocalizedString("action.reset_pin_appearance", comment: "")) {
            model.onAction(.resetAppearance)
        }
        Divider()
        Button(NSLocalizedString("action.close", comment: "")) {
            model.onAction(.close)
        }
        Button(NSLocalizedString("action.destroy_pin", comment: ""), role: .destructive) {
            model.onAction(.destroy)
        }
    }

    private func recognitionResult(_ analysis: OCRAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString("label.recognized_text", comment: ""))
                .font(.caption.weight(.semibold))
            Text(analysis.transcript)
                .textSelection(.enabled)
                .onDrag { NSItemProvider(object: analysis.transcript as NSString) }
            Button(NSLocalizedString("action.copy_all_recognized_text", comment: "")) {
                model.onAction(.copyText(
                    analysis.transcript,
                    sourceKey: "source.pastebuddy_ocr"
                ))
            }
            .controlSize(.small)
            ForEach(Array(analysis.barcodes.enumerated()), id: \.offset) { _, barcode in
                HStack {
                    Text(barcode.payload)
                        .textSelection(.enabled)
                    Spacer()
                    Button(NSLocalizedString("action.copy", comment: "")) {
                        model.onAction(.copyText(
                            barcode.payload,
                            sourceKey: "source.pastebuddy_ocr"
                        ))
                    }
                    if let url = barcode.url {
                        Button(NSLocalizedString("action.open_link", comment: "")) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxHeight: 180)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("label.recognized_text", comment: ""))
    }

    private func translationResult(_ result: NativeTranslationResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(result.sourceLanguageIdentifier) → \(result.targetLanguageIdentifier)")
                .font(.caption.weight(.semibold))
            Text(result.sourceText)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(result.translatedText)
                .textSelection(.enabled)
                .onDrag { NSItemProvider(object: result.translatedText as NSString) }
            Button(NSLocalizedString("action.copy_translation", comment: "")) {
                model.onAction(.copyText(
                    result.translatedText,
                    sourceKey: "source.pastebuddy_translation"
                ))
            }
            .controlSize(.small)
            Button(NSLocalizedString("action.pin_translation", comment: "")) {
                model.onAction(.pinText(result.translatedText))
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxHeight: 220)
        .background(.regularMaterial)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
