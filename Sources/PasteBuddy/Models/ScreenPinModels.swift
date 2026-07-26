import AppKit
import Foundation
import PasteBuddyCore

enum ScreenPinKind: String, Codable, Sendable {
    case image
    case text
    case files
    case color
    case latex

    static func resolve(item: ClipboardItem) -> ScreenPinKind {
        if item.payload.hasImageAsset {
            return .image
        }
        if !item.payload.allFileURLStrings.isEmpty {
            return .files
        }
        let text = item.payload.primaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        if ScreenPinColor.parse(text) != nil {
            return .color
        }
        if text.hasPrefix("$$")
            || text.hasPrefix("\\(")
            || text.contains("\\begin{") {
            return .latex
        }
        return .text
    }
}

struct ScreenPinColor: Equatable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    var hexString: String {
        String(
            format: "#%02X%02X%02X",
            Int(round(red * 255)),
            Int(round(green * 255)),
            Int(round(blue * 255))
        )
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    static func parse(_ value: String) -> ScreenPinColor? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") {
            let hex = String(trimmed.dropFirst())
            guard hex.count == 6 || hex.count == 8,
                  let integer = UInt64(hex, radix: 16) else {
                return nil
            }
            let alpha = hex.count == 8 ? CGFloat(integer & 0xFF) / 255 : 1
            let blueShift = hex.count == 8 ? 8 : 0
            return ScreenPinColor(
                red: CGFloat((integer >> (blueShift + 16)) & 0xFF) / 255,
                green: CGFloat((integer >> (blueShift + 8)) & 0xFF) / 255,
                blue: CGFloat((integer >> blueShift) & 0xFF) / 255,
                alpha: alpha
            )
        }

        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("rgb("), lowercased.hasSuffix(")") {
            let values = lowercased
                .dropFirst(4)
                .dropLast()
                .split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard values.count == 3, values.allSatisfy({ (0...255).contains($0) }) else {
                return nil
            }
            return ScreenPinColor(
                red: values[0] / 255,
                green: values[1] / 255,
                blue: values[2] / 255,
                alpha: 1
            )
        }

        let commaValues = lowercased
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if commaValues.count == 3,
           commaValues.allSatisfy({ (0...255).contains($0) }) {
            return ScreenPinColor(
                red: commaValues[0] / 255,
                green: commaValues[1] / 255,
                blue: commaValues[2] / 255,
                alpha: 1
            )
        }

        guard let color = NSColor(named: NSColor.Name(lowercased))?
            .usingColorSpace(.sRGB) else {
            return namedColors[lowercased]
        }
        return ScreenPinColor(
            red: color.redComponent,
            green: color.greenComponent,
            blue: color.blueComponent,
            alpha: color.alphaComponent
        )
    }

    private static let namedColors: [String: ScreenPinColor] = [
        "black": ScreenPinColor(red: 0, green: 0, blue: 0, alpha: 1),
        "white": ScreenPinColor(red: 1, green: 1, blue: 1, alpha: 1),
        "red": ScreenPinColor(red: 1, green: 0, blue: 0, alpha: 1),
        "green": ScreenPinColor(red: 0, green: 0.5, blue: 0, alpha: 1),
        "blue": ScreenPinColor(red: 0, green: 0, blue: 1, alpha: 1),
        "orange": ScreenPinColor(red: 1, green: 0.647, blue: 0, alpha: 1),
        "yellow": ScreenPinColor(red: 1, green: 1, blue: 0, alpha: 1),
        "purple": ScreenPinColor(red: 0.5, green: 0, blue: 0.5, alpha: 1),
    ]
}

struct ScreenPinGroup: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var colorHex: String?

    init(id: UUID = UUID(), name: String, colorHex: String? = nil) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }
}

struct ScreenPinState: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var itemID: UUID
    var kind: ScreenPinKind
    var title: String
    var frame: CGRect
    var opacity: Double
    var isLocked: Bool
    var isAlwaysOnTop: Bool
    var isClickThrough: Bool
    var isThumbnail: Bool
    var cropRect: CGRect?
    var groupID: UUID
    var closedAt: Date?

    init(
        id: UUID = UUID(),
        itemID: UUID,
        kind: ScreenPinKind,
        title: String,
        frame: CGRect,
        opacity: Double = 1,
        isLocked: Bool = false,
        isAlwaysOnTop: Bool = true,
        isClickThrough: Bool = false,
        isThumbnail: Bool = false,
        cropRect: CGRect? = nil,
        groupID: UUID,
        closedAt: Date? = nil
    ) {
        self.id = id
        self.itemID = itemID
        self.kind = kind
        self.title = title
        self.frame = frame
        self.opacity = min(max(opacity, 0.1), 1)
        self.isLocked = isLocked
        self.isAlwaysOnTop = isAlwaysOnTop
        self.isClickThrough = isClickThrough
        self.isThumbnail = isThumbnail
        self.cropRect = cropRect
        self.groupID = groupID
        self.closedAt = closedAt
    }
}

struct ScreenPinRegistry: Equatable, Sendable {
    private(set) var groups: [ScreenPinGroup]
    private(set) var activeGroupID: UUID
    private(set) var activePins: [ScreenPinState] = []
    private(set) var recentlyClosed: [ScreenPinState] = []
    var maximumRecentlyClosed = 20

    init(
        groups: [ScreenPinGroup]? = nil,
        activeGroupID: UUID? = nil,
        defaultGroupName: String = "Default"
    ) {
        let resolvedGroups = groups?.isEmpty == false
            ? groups!
            : [ScreenPinGroup(name: defaultGroupName)]
        self.groups = resolvedGroups
        self.activeGroupID = activeGroupID.flatMap { id in
            resolvedGroups.contains(where: { $0.id == id }) ? id : nil
        } ?? resolvedGroups[0].id
    }

    mutating func add(_ state: ScreenPinState) {
        var active = state
        active.closedAt = nil
        activePins.removeAll { $0.id == active.id }
        activePins.append(active)
    }

    @discardableResult
    mutating func close(id: UUID, at date: Date = Date()) -> ScreenPinState? {
        guard let index = activePins.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        var closed = activePins.remove(at: index)
        closed.closedAt = date
        recentlyClosed.removeAll { $0.id == id }
        recentlyClosed.insert(closed, at: 0)
        recentlyClosed = Array(recentlyClosed.prefix(maximumRecentlyClosed))
        return closed
    }

    mutating func destroy(id: UUID) {
        activePins.removeAll { $0.id == id }
        recentlyClosed.removeAll { $0.id == id }
    }

    @discardableResult
    mutating func restoreMostRecent() -> ScreenPinState? {
        guard var restored = recentlyClosed.first else { return nil }
        recentlyClosed.removeFirst()
        restored.closedAt = nil
        add(restored)
        return restored
    }

    mutating func update(_ state: ScreenPinState) {
        guard let index = activePins.firstIndex(where: { $0.id == state.id }) else {
            return
        }
        activePins[index] = state
    }

    mutating func createGroup(name: String, colorHex: String? = nil) -> ScreenPinGroup? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !groups.contains(where: {
                  $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
              }) else {
            return nil
        }
        let group = ScreenPinGroup(name: trimmed, colorHex: colorHex)
        groups.append(group)
        return group
    }

    mutating func selectGroup(_ id: UUID) -> Bool {
        guard groups.contains(where: { $0.id == id }) else { return false }
        activeGroupID = id
        return true
    }
}
