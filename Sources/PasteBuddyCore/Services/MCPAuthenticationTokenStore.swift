import CryptoKit
import Foundation

public protocol MCPAuthenticationTokenProviding: Sendable {
    func loadOrCreateToken() throws -> Data
    func invalidateToken() throws
}

public struct KeychainMCPAuthenticationTokenStore: MCPAuthenticationTokenProviding {
    private let keyStore: KeychainKeyMaterialStore

    public init(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        keyStore = KeychainKeyMaterialStore(
            service: "com.alexjiang.PasteBuddy.mcp-http",
            account: bundleIdentifier ?? "com.alexjiang.PasteBuddy"
        )
    }

    public func loadOrCreateToken() throws -> Data {
        try keyStore.loadOrCreateKeyData()
    }

    public func invalidateToken() throws {
        try keyStore.deleteStoredKeyMaterial()
    }
}

public enum MCPAuthenticationToken {
    public static let environmentVariable = "PASTEBUDDY_MCP_TOKEN"

    public static func encoded(_ token: Data) -> String {
        token.base64EncodedString()
    }

    public static func constantTimeMatches(_ candidate: String, token: Data) -> Bool {
        constantTimeMatches(candidate, expected: encoded(token))
    }

    public static func randomChallenge() throws -> Data {
        try KeychainKeyMaterialStore.randomKeyData()
    }

    public static func serverProof(challenge: Data, token: Data) -> String {
        let message = Data("pastebuddy-mcp-server-v1".utf8) + challenge
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: token)))
            .base64EncodedString()
    }

    public static func clientProof(challenge: Data, token: Data) -> String {
        let message = Data("pastebuddy-mcp-client-v1".utf8) + challenge
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: token)))
            .base64EncodedString()
    }

    public static func constantTimeMatches(_ candidate: String, expected: String) -> Bool {
        let expected = Array(expected.utf8)
        let supplied = Array(candidate.utf8)
        var difference = expected.count ^ supplied.count
        for index in 0..<max(expected.count, supplied.count) {
            difference |= Int((index < expected.count ? expected[index] : 0)
                ^ (index < supplied.count ? supplied[index] : 0))
        }
        return difference == 0
    }
}
