import AppKit

enum SettingsToolbarConfiguration {
    static func visibleIdentifiers(
        from identifiers: [NSToolbarItem.Identifier]
    ) -> [NSToolbarItem.Identifier] {
        identifiers.filter { identifier in
            identifier.rawValue != NSToolbarItem.Identifier.toggleSidebar.rawValue
                && identifier.rawValue.contains("toggleSidebar") == false
        }
    }
}
