import SwiftUI

enum PasteBuddyMotion {
    static let selectionAnimation: Animation? = nil

    static func performInstantSelection(_ updates: () -> Void) {
        var transaction = Transaction(animation: selectionAnimation)
        transaction.disablesAnimations = true
        withTransaction(transaction, updates)
    }
}
