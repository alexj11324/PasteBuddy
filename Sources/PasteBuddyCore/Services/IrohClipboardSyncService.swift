import Foundation
import IrohLib
import Observation
import Security

public enum IrohClipboardSyncConnectionState: Equatable, Sendable {
    case idle
    case binding
    case ready
    case connecting
    case connected(peerShortId: String)
    case failed(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

public struct IrohClipboardSyncEnvelope: Codable, Equatable, Sendable {
    public var version: Int
    public var sentAt: Date
    public var item: ClipboardItem

    public init(version: Int = 1, sentAt: Date = Date(), item: ClipboardItem) {
        self.version = version
        self.sentAt = sentAt
        self.item = item
    }
}

enum IrohClipboardWireFormat {
    static let alpn = Data("pastebuddy-clipboard-sync/1".utf8)
    static let maxFrameBytes = 8 * 1024 * 1024

    static func encode(_ envelope: IrohClipboardSyncEnvelope) throws -> Data {
        let payload = try JSONEncoder.pasteBuddy.encode(envelope)
        guard payload.count <= maxFrameBytes else {
            throw IrohClipboardSyncError.frameTooLarge(payload.count)
        }
        var length = UInt32(payload.count).littleEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        return frame
    }

    static func decode(lengthPrefix: Data, body: Data) throws -> IrohClipboardSyncEnvelope {
        guard lengthPrefix.count == MemoryLayout<UInt32>.size else {
            throw IrohClipboardSyncError.invalidFrame
        }
        let declaredLength = lengthPrefix.withUnsafeBytes { rawBuffer in
            UInt32(littleEndian: rawBuffer.load(as: UInt32.self))
        }
        guard declaredLength == body.count, body.count <= maxFrameBytes else {
            throw IrohClipboardSyncError.invalidFrame
        }
        return try JSONDecoder.pasteBuddy.decode(IrohClipboardSyncEnvelope.self, from: body)
    }
}

public enum IrohClipboardSyncError: LocalizedError, Equatable {
    case invalidPairingCode
    case invalidPeerEndpointId
    case noEndpoint
    case noSession
    case invalidFrame
    case frameTooLarge(Int)
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case invalidSecretKey

    public var errorDescription: String? {
        switch self {
        case .invalidPairingCode:
            "PasteBuddy pairing code is invalid."
        case .invalidPeerEndpointId:
            "Peer endpoint id is invalid."
        case .noEndpoint:
            "Iroh endpoint is not ready."
        case .noSession:
            "No active iroh clipboard session."
        case .invalidFrame:
            "Iroh clipboard frame is invalid."
        case .frameTooLarge(let byteCount):
            "Iroh clipboard frame is too large: \(byteCount) bytes."
        case .keychainReadFailed(let status):
            "Iroh identity Keychain read failed with status \(status)."
        case .keychainWriteFailed(let status):
            "Iroh identity Keychain write failed with status \(status)."
        case .invalidSecretKey:
            "Stored iroh identity is invalid."
        }
    }
}

@MainActor
@Observable
public final class IrohClipboardSyncService {
    public private(set) var endpointId = ""
    public var pairingURL: URL? {
        Self.pairingURL(endpointId: endpointId)
    }
    public var peerEndpointId: String {
        didSet { defaults.set(peerEndpointId, forKey: Self.peerEndpointDefaultsKey) }
    }
    public private(set) var connectionState: IrohClipboardSyncConnectionState = .idle
    public private(set) var lastSentAt: Date?
    public private(set) var lastReceivedAt: Date?
    public private(set) var lastReceivedTitle: String?

    @ObservationIgnored public var onItemReceived: (@MainActor (ClipboardItem) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let identityStore: IrohClipboardIdentityStore
    @ObservationIgnored private var endpoint: Endpoint?
    @ObservationIgnored private var acceptTask: Task<Void, Never>?
    @ObservationIgnored private var currentSession: IrohClipboardSession?

    private static let peerEndpointDefaultsKey = "pastebuddy.iroh.peerEndpointId"
    nonisolated private static let pairingScheme = "pastebuddy"
    nonisolated private static let pairingHost = "iroh-pair"

    public init(
        defaults: UserDefaults = .standard,
        identityStore: IrohClipboardIdentityStore = .standard
    ) {
        self.defaults = defaults
        self.identityStore = identityStore
        self.peerEndpointId = defaults.string(forKey: Self.peerEndpointDefaultsKey) ?? ""
    }

    deinit {
        acceptTask?.cancel()
        currentSession?.stop()
    }

    public func start() async {
        guard endpoint == nil else { return }
        connectionState = .binding
        do {
            let identity = try identityStore.loadOrCreate()
            endpointId = identity.endpointId
            let endpoint = try await Endpoint.bind(options: EndpointOptions(
                preset: presetN0(),
                secretKey: identity.secretKey.toBytes(),
                alpns: [IrohClipboardWireFormat.alpn]
            ))
            self.endpoint = endpoint
            connectionState = .ready
            acceptTask = Task { [weak self] in
                await self?.runAcceptLoop()
            }
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }

    public func connectToPeer() async {
        await start()
        guard let endpoint else {
            connectionState = .failed(IrohClipboardSyncError.noEndpoint.localizedDescription)
            return
        }
        let trimmed = peerEndpointId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let peerId = try? EndpointId.fromString(s: trimmed) else {
            connectionState = .failed(IrohClipboardSyncError.invalidPeerEndpointId.localizedDescription)
            return
        }
        connectionState = .connecting
        let address = EndpointAddr(id: peerId, relayUrl: nil, addresses: [])
        do {
            let connection = try await endpoint.connect(addr: address, alpn: IrohClipboardWireFormat.alpn)
            let stream = try await connection.openBi()
            adoptSession(stream: stream, connection: connection, remoteIdHex: peerId.description)
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }

    public func applyPairingCode(_ code: String) throws {
        peerEndpointId = try Self.peerEndpointId(fromPairingCode: code)
    }

    nonisolated public static func pairingURL(endpointId: String) -> URL? {
        let trimmed = endpointId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = pairingScheme
        components.host = pairingHost
        components.queryItems = [
            URLQueryItem(name: "endpoint", value: trimmed)
        ]
        return components.url
    }

    nonisolated public static func peerEndpointId(fromPairingCode code: String) throws -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == pairingScheme,
              components.host == pairingHost,
              let endpoint = components.queryItems?.first(where: { $0.name == "endpoint" })?.value?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !endpoint.isEmpty else {
            throw IrohClipboardSyncError.invalidPairingCode
        }
        return endpoint
    }

    @discardableResult
    public func send(_ item: ClipboardItem) async -> Bool {
        guard let currentSession else {
            connectionState = .failed(IrohClipboardSyncError.noSession.localizedDescription)
            return false
        }
        return await send(item) { envelope in
            try await currentSession.send(envelope)
        }
    }

    @discardableResult
    func send(
        _ item: ClipboardItem,
        transport: @escaping @Sendable (IrohClipboardSyncEnvelope) async throws -> Void
    ) async -> Bool {
        do {
            try await transport(IrohClipboardSyncEnvelope(item: item))
            lastSentAt = Date()
            return true
        } catch let error as IrohClipboardSyncError {
            guard case .frameTooLarge = error else {
                connectionState = .failed(error.localizedDescription)
                return false
            }
            let slimmedItem = Self.slimmedItemForFrameRetry(from: item)
            do {
                try await transport(IrohClipboardSyncEnvelope(item: slimmedItem))
                lastSentAt = Date()
                return true
            } catch {
                return false
            }
        } catch {
            connectionState = .failed(error.localizedDescription)
            return false
        }
    }

    public func sendIfConnected(_ item: ClipboardItem) async {
        guard currentSession != nil else { return }
        _ = await send(item)
    }

    private func runAcceptLoop() async {
        while !Task.isCancelled {
            guard let incoming = await endpoint?.acceptNext() else { return }
            do {
                let accepting = try await incoming.accept()
                guard try await accepting.alpn() == IrohClipboardWireFormat.alpn else {
                    continue
                }
                let connection = try await accepting.connect()
                let stream = try await connection.acceptBi()
                adoptSession(stream: stream, connection: connection, remoteIdHex: connection.remoteId().description)
            } catch {
                continue
            }
        }
    }

    private func adoptSession(stream: BiStream, connection: Connection, remoteIdHex: String) {
        currentSession?.stop()
        let session = IrohClipboardSession(
            stream: stream,
            onEnvelopeReceived: { [weak self] envelope in
                Task { @MainActor in
                    self?.receive(envelope)
                }
            },
            onClosed: { [weak self] in
                Task { @MainActor in
                    self?.handleSessionClosed()
                }
            }
        )
        currentSession = session
        session.start()
        connectionState = .connected(peerShortId: String(remoteIdHex.prefix(10)))
    }

    private func receive(_ envelope: IrohClipboardSyncEnvelope) {
        lastReceivedAt = envelope.sentAt
        lastReceivedTitle = envelope.item.title
        onItemReceived?(envelope.item)
    }

    private func handleSessionClosed() {
        currentSession = nil
        if case .connected = connectionState {
            connectionState = .ready
        }
    }

    static func slimmedItemForFrameRetry(from item: ClipboardItem) -> ClipboardItem {
        var slimmed = item
        slimmed.payload.rtfData = nil
        slimmed.payload.rtfAssetID = nil
        slimmed.payload.rtfByteCount = nil
        slimmed.payload.imageData = nil
        slimmed.payload.imageAssetID = nil
        slimmed.payload.imageByteCount = nil
        slimmed.refreshSearchDocument()
        return slimmed
    }
}

public struct IrohClipboardIdentity: Sendable {
    public let secretKey: SecretKey
    public let endpointId: String
}

public final class IrohClipboardIdentityStore: @unchecked Sendable {
    public static let standard = IrohClipboardIdentityStore()

    private let service: String
    private let account: String

    public init(
        service: String = "com.alexjiang.PasteBuddy.iroh",
        account: String = "clipboard-sync-secret-key"
    ) {
        self.service = service
        self.account = account
    }

    public func loadOrCreate() throws -> IrohClipboardIdentity {
        if let stored = try load() {
            return stored
        }
        let secretKey = SecretKey.generate()
        try save(secretKey.toBytes())
        return IrohClipboardIdentity(secretKey: secretKey, endpointId: secretKey.public().description)
    }

    private func load() throws -> IrohClipboardIdentity? {
        var item: CFTypeRef?
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw IrohClipboardSyncError.keychainReadFailed(status)
        }
        guard let data = item as? Data,
              let secretKey = try? SecretKey.fromBytes(bytes: data) else {
            throw IrohClipboardSyncError.invalidSecretKey
        }
        return IrohClipboardIdentity(secretKey: secretKey, endpointId: secretKey.public().description)
    }

    private func save(_ data: Data) throws {
        var query = baseQuery()
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecValueData as String] = data
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            var updateQuery = baseQuery()
            updateQuery[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw IrohClipboardSyncError.keychainWriteFailed(updateStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw IrohClipboardSyncError.keychainWriteFailed(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

private final class IrohClipboardSession: @unchecked Sendable {
    private let stream: BiStream
    private let sender: IrohClipboardSender
    private let onEnvelopeReceived: @Sendable (IrohClipboardSyncEnvelope) -> Void
    private let onClosed: @Sendable () -> Void
    private var receiveTask: Task<Void, Never>?

    init(
        stream: BiStream,
        onEnvelopeReceived: @escaping @Sendable (IrohClipboardSyncEnvelope) -> Void,
        onClosed: @escaping @Sendable () -> Void
    ) {
        self.stream = stream
        self.sender = IrohClipboardSender(stream: stream)
        self.onEnvelopeReceived = onEnvelopeReceived
        self.onClosed = onClosed
    }

    func start() {
        receiveTask = Task.detached { [weak self] in
            await self?.runReceiveLoop()
        }
    }

    func stop() {
        receiveTask?.cancel()
    }

    func send(_ envelope: IrohClipboardSyncEnvelope) async throws {
        try await sender.send(envelope)
    }

    private func runReceiveLoop() async {
        let receiver = stream.recv()
        while !Task.isCancelled {
            do {
                let lengthPrefix = try await receiver.readExact(size: UInt32(MemoryLayout<UInt32>.size))
                let byteCount = lengthPrefix.withUnsafeBytes { rawBuffer in
                    UInt32(littleEndian: rawBuffer.load(as: UInt32.self))
                }
                guard byteCount <= IrohClipboardWireFormat.maxFrameBytes else {
                    break
                }
                let body = try await receiver.readExact(size: byteCount)
                let envelope = try IrohClipboardWireFormat.decode(lengthPrefix: lengthPrefix, body: body)
                onEnvelopeReceived(envelope)
            } catch {
                break
            }
        }
        onClosed()
    }
}

private actor IrohClipboardSender {
    private let stream: BiStream

    init(stream: BiStream) {
        self.stream = stream
    }

    func send(_ envelope: IrohClipboardSyncEnvelope) async throws {
        let frame = try IrohClipboardWireFormat.encode(envelope)
        try await stream.send().writeAll(buf: frame)
    }
}
