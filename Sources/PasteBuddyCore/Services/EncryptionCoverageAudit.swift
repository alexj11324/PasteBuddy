import Foundation

public enum EncryptedDataSurface: String, CaseIterable, Codable, Identifiable, Sendable {
    case clipboardText
    case clipboardURLs
    case fileReferences
    case imageAndScreenshotBytes
    case ocrMetadata
    case thumbnails
    case pinboards
    case itemOrganizationMetadata
    case privacySettings
    case syncPackages
    case sharedPinboardMetadata
    case sharedPinboardInvitations
    case entitlementMetadata
    case mcpAccessAudit
    case encryptionKeyMaterial

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .clipboardText: "Clipboard text"
        case .clipboardURLs: "Clipboard links"
        case .fileReferences: "File references"
        case .imageAndScreenshotBytes: "Image and screenshot bytes"
        case .ocrMetadata: "OCR metadata"
        case .thumbnails: "Thumbnails"
        case .pinboards: "Pinboards"
        case .itemOrganizationMetadata: "Item organization metadata"
        case .privacySettings: "Privacy settings"
        case .syncPackages: "Sync packages"
        case .sharedPinboardMetadata: "Shared pinboard metadata"
        case .sharedPinboardInvitations: "Shared pinboard invitations"
        case .entitlementMetadata: "Entitlement metadata"
        case .mcpAccessAudit: "MCP access audit"
        case .encryptionKeyMaterial: "Encryption key material"
        }
    }
}

public struct EncryptionCoverageItem: Codable, Equatable, Sendable {
    public var surface: EncryptedDataSurface
    public var protection: String
    public var plaintextFallbackAllowed: Bool

    public init(
        surface: EncryptedDataSurface,
        protection: String,
        plaintextFallbackAllowed: Bool = false
    ) {
        self.surface = surface
        self.protection = protection
        self.plaintextFallbackAllowed = plaintextFallbackAllowed
    }
}

public struct EncryptionCoverageReport: Codable, Equatable, Sendable {
    public var items: [EncryptionCoverageItem]

    public init(items: [EncryptionCoverageItem]) {
        self.items = items
    }

    public var uncoveredSurfaces: [EncryptedDataSurface] {
        let covered = Set(items.map(\.surface))
        return EncryptedDataSurface.allCases.filter { !covered.contains($0) }
    }

    public var plaintextFallbackSurfaces: [EncryptedDataSurface] {
        items.filter(\.plaintextFallbackAllowed).map(\.surface)
    }
}

public enum EncryptionCoverageAudit {
    public static let current = EncryptionCoverageReport(items: [
        EncryptionCoverageItem(
            surface: .clipboardText,
            protection: "AES-GCM encrypted snapshot envelope; key material in this-device-only Keychain."
        ),
        EncryptionCoverageItem(
            surface: .clipboardURLs,
            protection: "AES-GCM encrypted snapshot envelope; no plaintext search index."
        ),
        EncryptionCoverageItem(
            surface: .fileReferences,
            protection: "Encrypted snapshot metadata; external file bytes are never copied without an explicit future blob vault."
        ),
        EncryptionCoverageItem(
            surface: .imageAndScreenshotBytes,
            protection: "Image data is stored inside the AES-GCM encrypted snapshot envelope."
        ),
        EncryptionCoverageItem(
            surface: .ocrMetadata,
            protection: "Apple Vision OCR text is saved as encrypted item metadata after local recognition."
        ),
        EncryptionCoverageItem(
            surface: .thumbnails,
            protection: "No plaintext thumbnail cache exists; generated thumbnail data must remain in the encrypted envelope."
        ),
        EncryptionCoverageItem(
            surface: .pinboards,
            protection: "Pinboard names, colors, order, item membership, and sharing state live inside the encrypted snapshot."
        ),
        EncryptionCoverageItem(
            surface: .itemOrganizationMetadata,
            protection: "User titles, item labels, and reusable content categories are encrypted with the item snapshot and searchable only after local decryption."
        ),
        EncryptionCoverageItem(
            surface: .privacySettings,
            protection: "Custom capture rules, capture toggles, pause state, and excluded apps are encrypted with the snapshot."
        ),
        EncryptionCoverageItem(
            surface: .syncPackages,
            protection: "Cloud sync package builder only emits encrypted snapshot envelopes and rejects blocked sync states."
        ),
        EncryptionCoverageItem(
            surface: .sharedPinboardMetadata,
            protection: "Participants, permissions, and share-link hashes are encrypted; raw link tokens are not persisted."
        ),
        EncryptionCoverageItem(
            surface: .sharedPinboardInvitations,
            protection: "Pending invitation packages and inbox status are encrypted with the snapshot; invitation packages contain wrapped board keys, not unwrapped board keys or private key material."
        ),
        EncryptionCoverageItem(
            surface: .entitlementMetadata,
            protection: "Trial, purchase, restore, and team seat state are encrypted with the snapshot; no payment secrets are stored."
        ),
        EncryptionCoverageItem(
            surface: .mcpAccessAudit,
            protection: "MCP access metadata is stored in the encrypted snapshot and omits search queries, clipboard payloads, OCR text, and image bytes."
        ),
        EncryptionCoverageItem(
            surface: .encryptionKeyMaterial,
            protection: "AES-GCM key material can be wrapped by a Secure Enclave private key; the wrapped key and encrypted snapshot are stored separately."
        )
    ])
}
