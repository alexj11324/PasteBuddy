import AppKit
import Foundation
import SwiftUI

enum PasteBuddyMotion {
    static let selectionDuration: TimeInterval = 0
    static let hoverDuration: TimeInterval = 0.18
    static let filterDuration: TimeInterval = 0.36
    static let panelShowDuration: TimeInterval = 0.18
    static let panelHideDuration: TimeInterval = 0.16

    static let selectionAnimation: Animation? = nil
    static let hoverAnimation = Animation.smooth(duration: hoverDuration, extraBounce: 0.04)
    static let filterAnimation = Animation.smooth(duration: filterDuration, extraBounce: 0.09)

    static var shouldReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func duration(_ duration: TimeInterval) -> TimeInterval {
        shouldReduceMotion ? 0 : duration
    }

    static func reduced(_ animation: Animation?) -> Animation? {
        shouldReduceMotion ? nil : animation
    }

    static func performInstantSelection(_ updates: () -> Void) {
        var transaction = Transaction(animation: selectionAnimation)
        transaction.disablesAnimations = true
        withTransaction(transaction, updates)
    }
}
