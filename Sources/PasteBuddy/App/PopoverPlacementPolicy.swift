import AppKit

struct PopoverPlacementDecision: Equatable {
    let edge: NSRectEdge
    let maximumContentSize: NSSize
}

enum PopoverPlacementPolicy {
    private struct Candidate {
        let edge: NSRectEdge
        let availableSize: NSSize
    }

    static func decision(
        preferredEdge: NSRectEdge,
        desiredContentSize: NSSize,
        containingWindowFrame: NSRect,
        screenFrame: NSRect,
        margin: CGFloat = 12
    ) -> PopoverPlacementDecision {
        let candidates = orderedEdges(preferredEdge: preferredEdge).map { edge in
            let availableSize = availableContentSize(
                outside: containingWindowFrame,
                within: screenFrame,
                edge: edge,
                margin: margin
            )
            return Candidate(edge: edge, availableSize: availableSize)
        }

        if let fittingCandidate = candidates.first(where: { candidate in
            candidate.availableSize.width >= desiredContentSize.width
                && candidate.availableSize.height >= desiredContentSize.height
        }) {
            return PopoverPlacementDecision(
                edge: fittingCandidate.edge,
                maximumContentSize: desiredContentSize
            )
        }

        let bestCandidate = candidates.max { lhs, rhs in
            lhs.availableSize.width * lhs.availableSize.height
                < rhs.availableSize.width * rhs.availableSize.height
        }
        let edge = bestCandidate?.edge ?? preferredEdge
        let maximumSize = bestCandidate?.availableSize ?? desiredContentSize
        return PopoverPlacementDecision(
            edge: edge,
            maximumContentSize: NSSize(
                width: min(desiredContentSize.width, maximumSize.width),
                height: min(desiredContentSize.height, maximumSize.height)
            )
        )
    }

    private static func orderedEdges(preferredEdge: NSRectEdge) -> [NSRectEdge] {
        [preferredEdge, .minX, .maxX, .maxY, .minY].reduce(into: []) { result, edge in
            if !result.contains(edge) {
                result.append(edge)
            }
        }
    }

    private static func availableContentSize(
        outside windowFrame: NSRect,
        within screenFrame: NSRect,
        edge: NSRectEdge,
        margin: CGFloat
    ) -> NSSize {
        let usableScreenWidth = max(0, screenFrame.width - margin * 2)
        let usableScreenHeight = max(0, screenFrame.height - margin * 2)
        switch edge {
        case .minX:
            return NSSize(
                width: max(0, windowFrame.minX - screenFrame.minX - margin),
                height: usableScreenHeight
            )
        case .maxX:
            return NSSize(
                width: max(0, screenFrame.maxX - windowFrame.maxX - margin),
                height: usableScreenHeight
            )
        case .minY:
            return NSSize(
                width: usableScreenWidth,
                height: max(0, windowFrame.minY - screenFrame.minY - margin)
            )
        case .maxY:
            return NSSize(
                width: usableScreenWidth,
                height: max(0, screenFrame.maxY - windowFrame.maxY - margin)
            )
        @unknown default:
            return .zero
        }
    }
}
