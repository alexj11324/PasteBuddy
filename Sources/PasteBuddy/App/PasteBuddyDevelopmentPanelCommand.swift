import Foundation
import PasteBuddyCore

enum PasteBuddyDevelopmentPanelCommand: Equatable {
    case show(ClipboardPanelDisplayMode)
    case toggle

    static func parse(_ url: URL, identity: PasteBuddyRuntimeIdentity) -> Self? {
        guard identity.bundleIdentifier == "com.alexjiang.PasteBuddy.dev",
              identity.signingChannel == "development",
              identity.stableAppPath == "/Applications/PasteBuddy Dev.app",
              identity.isRunningFromStablePath,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "pastebuddy-dev",
              components.host == "panel",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        return switch components.percentEncodedPath {
        case "/side": .show(.sidePanel)
        case "/shelf": .show(.shelf)
        case "/toggle": .toggle
        default: nil
        }
    }
}
