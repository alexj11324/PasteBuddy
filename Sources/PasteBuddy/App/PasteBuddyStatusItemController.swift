import AppKit
import PasteBuddyCore

@MainActor
final class PasteBuddyStatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let statusMenu: NSMenu
    private let menuProvider: () -> NSMenu
    private let primaryAction: () -> Void

    init(menuProvider: @escaping () -> NSMenu, primaryAction: @escaping () -> Void) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusMenu = NSMenu(title: NSLocalizedString("brand.pastebuddy", comment: ""))
        self.menuProvider = menuProvider
        self.primaryAction = primaryAction
        super.init()
        statusMenu.delegate = self
        installButtonAction()
    }

    deinit {
        MainActor.assumeIsolated {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    func update(status: MacMenuBarStatus) {
        guard let button = statusItem.button else { return }
        button.image = Self.menuBarIcon(
            accessibilityDescription: NSLocalizedString(status.title, comment: "")
        )
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = NSLocalizedString("message.click_for_pastebuddy_menu", comment: "")
        button.setAccessibilityLabel(NSLocalizedString("label.pastebuddy_menu_bar_item", comment: ""))
    }

    func updateUnavailable(message: String) {
        updateRestricted(message: message)
    }

    func updateLoading(message: String) {
        updateRestricted(message: message)
    }

    private func updateRestricted(message: String) {
        guard let button = statusItem.button else { return }
        button.image = Self.menuBarIcon(accessibilityDescription: message)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = message
        button.setAccessibilityLabel(message)
    }

    static func restrictedMenu(
        title: String,
        statusMessage: String,
        settingsTitle: String,
        quitTitle: String,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.addItem(disabledMenuItem(
            statusMessage,
            systemImageName: "exclamationmark.triangle"
        ))
        menu.addItem(actionMenuItem(
            settingsTitle,
            systemImageName: "gearshape",
            keyEquivalent: ",",
            keyEquivalentModifierMask: .command,
            action: onOpenSettings
        ))
        menu.addItem(.separator())
        menu.addItem(actionMenuItem(
            quitTitle,
            systemImageName: "power",
            keyEquivalent: "q",
            keyEquivalentModifierMask: .command,
            action: onQuit
        ))
        return menu
    }

    func containsScreenPoint(_ point: CGPoint) -> Bool {
        guard let button = statusItem.button, let window = button.window else {
            return false
        }
        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrame = window.convertToScreen(buttonFrameInWindow).insetBy(dx: -4, dy: -4)
        return buttonFrame.contains(point)
    }

    static func disabledMenuItem(_ title: String, systemImageName: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.image = image(named: systemImageName, description: title)
        return item
    }

    static func actionMenuItem(
        _ title: String,
        systemImageName: String? = nil,
        enabled: Bool = true,
        keyEquivalent: String = "",
        keyEquivalentModifierMask: NSEvent.ModifierFlags? = nil,
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let itemAction = PasteBuddyStatusMenuItemAction(action)
        let item = NSMenuItem(
            title: title,
            action: #selector(PasteBuddyStatusMenuItemAction.invoke),
            keyEquivalent: keyEquivalent
        )
        item.target = itemAction
        item.representedObject = itemAction
        item.isEnabled = enabled
        item.image = image(named: systemImageName, description: title)
        if let keyEquivalentModifierMask {
            item.keyEquivalentModifierMask = keyEquivalentModifierMask
        }
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        reloadStatusMenu(into: menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        statusItem.menu = nil
        installButtonAction()
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showStatusMenu()
        } else {
            primaryAction()
        }
    }

    private func showStatusMenu() {
        reloadStatusMenu(into: statusMenu)
        statusItem.menu = statusMenu
        statusItem.button?.performClick(nil)
    }

    private func reloadStatusMenu(into menu: NSMenu) {
        menu.removeAllItems()

        let latestMenu = menuProvider()
        while !latestMenu.items.isEmpty {
            let item = latestMenu.items[0]
            latestMenu.removeItem(at: 0)
            menu.addItem(item)
        }
    }

    private func installButtonAction() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private static func image(named systemImageName: String?, description: String) -> NSImage? {
        guard let systemImageName else { return nil }
        return NSImage(systemSymbolName: systemImageName, accessibilityDescription: description)
    }

    private static func menuBarIcon(accessibilityDescription: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let path = Self.appIconOutlinePath(in: rect.insetBy(dx: 2.4, dy: 2.2))
            path.lineWidth = 1.8
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    nonisolated private static func appIconOutlinePath(in rect: CGRect) -> NSBezierPath {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        let path = NSBezierPath()
        path.move(to: point(0.18, 0.08))
        path.line(to: point(0.18, 0.72))
        path.curve(to: point(0.36, 0.92), controlPoint1: point(0.18, 0.84), controlPoint2: point(0.24, 0.92))
        path.line(to: point(0.62, 0.92))
        path.curve(to: point(0.95, 0.62), controlPoint1: point(0.82, 0.92), controlPoint2: point(0.95, 0.80))
        path.curve(to: point(0.66, 0.39), controlPoint1: point(0.95, 0.47), controlPoint2: point(0.82, 0.39))
        path.curve(to: point(0.51, 0.16), controlPoint1: point(0.57, 0.39), controlPoint2: point(0.53, 0.26))
        path.curve(to: point(0.34, 0.08), controlPoint1: point(0.47, 0.08), controlPoint2: point(0.40, 0.08))
        path.close()
        return path
    }
}

@MainActor
private final class PasteBuddyStatusMenuItemAction: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invoke() {
        action()
    }
}
