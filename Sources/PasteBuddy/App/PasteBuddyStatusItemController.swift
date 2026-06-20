import AppKit
import PasteBuddyCore

@MainActor
final class PasteBuddyStatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let statusMenu: NSMenu
    private let menuProvider: () -> NSMenu

    init(menuProvider: @escaping () -> NSMenu) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusMenu = NSMenu(title: "brand.pastebuddy")
        self.menuProvider = menuProvider
        super.init()
        statusMenu.delegate = self
        statusItem.menu = statusMenu
    }

    deinit {
        MainActor.assumeIsolated {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    func update(status: MacMenuBarStatus) {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: status.systemImageName,
            accessibilityDescription: NSLocalizedString(status.title, comment: "")
        )
        button.toolTip = NSLocalizedString("message.click_for_pastebuddy_menu", comment: "")
        button.setAccessibilityLabel(NSLocalizedString("label.pastebuddy_menu_bar_item", comment: ""))
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
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let itemAction = PasteBuddyStatusMenuItemAction(action)
        let item = NSMenuItem(
            title: title,
            action: #selector(PasteBuddyStatusMenuItemAction.invoke),
            keyEquivalent: ""
        )
        item.target = itemAction
        item.representedObject = itemAction
        item.isEnabled = enabled
        item.image = image(named: systemImageName, description: title)
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        menu.removeAllItems()

        let latestMenu = menuProvider()
        while !latestMenu.items.isEmpty {
            let item = latestMenu.items[0]
            latestMenu.removeItem(at: 0)
            menu.addItem(item)
        }
    }

    private static func image(named systemImageName: String?, description: String) -> NSImage? {
        guard let systemImageName else { return nil }
        return NSImage(systemSymbolName: systemImageName, accessibilityDescription: description)
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
