import Foundation
import IrohLib
import Observation
import OSLog
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
    static let supportedEnvelopeVersion = 1

    static func encode(_ envelope: IrohClipboardSyncEnvelope) throws -> Data {
        if let byteCount = obviouslyOversizedInlineByteCount(in: envelope.item) {
            throw IrohClipboardSyncError.frameTooLarge(byteCount)
        }
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
            UInt32(littleEndian: rawBuffer.loadUnaligned(as: UInt32.self))
        }
        guard declaredLength == body.count, body.count <= maxFrameBytes else {
            throw IrohClipboardSyncError.invalidFrame
        }
        let envelope = try JSONDecoder.pasteBuddy.decode(IrohClipboardSyncEnvelope.self, from: body)
        guard envelope.version == supportedEnvelopeVersion else {
            throw IrohClipboardSyncError.unsupportedEnvelopeVersion(envelope.version)
        }
        return envelope
    }

    private static func obviouslyOversizedInlineByteCount(in item: ClipboardItem) -> Int? {
        var lowerBound = 0
        let payload = item.payload

        func append(_ byteCount: Int) -> Int? {
            guard byteCount <= Int.max - lowerBound else { return Int.max }
            lowerBound += byteCount
            return lowerBound > maxFrameBytes ? lowerBound : nil
        }

        for data in [payload.rtfData, payload.imageData].compactMap({ $0 }) {
            let byteCount = base64EncodedByteCount(for: data.count)
            if let oversizedByteCount = append(byteCount) {
                return oversizedByteCount
            }
        }
        let strings = [
            item.sourceAppName,
            item.sourceBundleIdentifier,
            item.deviceName,
            item.title,
            payload.text,
            payload.htmlString,
            payload.rtfAssetID,
            payload.urlString,
            payload.fileURLString,
            payload.imageAssetID,
            payload.ocrText,
            item.searchDocument.normalizedText,
            item.searchDocument.previewHeadline,
            item.searchDocument.previewBody,
            item.searchDocument.contentHash,
            item.searchDocument.searchHash
        ] + item.labels.map(Optional.some) + payload.fileURLStrings.map(Optional.some)
        for string in strings.compactMap({ $0 }) {
            let byteCount = string.utf8.count
            if let oversizedByteCount = append(byteCount) {
                return oversizedByteCount
            }
        }
        return nil
    }

    private static func base64EncodedByteCount(for rawByteCount: Int) -> Int {
        guard rawByteCount <= Int.max - 2 else { return Int.max }
        let groupCount = (rawByteCount + 2) / 3
        guard groupCount <= Int.max / 4 else { return Int.max }
        return groupCount * 4
    }
}

public enum IrohClipboardSyncError: LocalizedError, Equatable {
    case invalidPairingCode
    case invalidPeerEndpointId
    case noEndpoint
    case noSession
    case invalidFrame
    case frameTooLarge(Int)
    case unsupportedEnvelopeVersion(Int)
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case invalidSecretKey

    public var errorDescription: String? {
        switch self {
        case .invalidPairingCode:
            PasteBuddyLocalization.string(
                "error.iroh.invalid_pairing_code",
                defaultValue: "PasteBuddy pairing code is invalid."
            )
        case .invalidPeerEndpointId:
            PasteBuddyLocalization.string(
                "error.iroh.invalid_peer_endpoint_id",
                defaultValue: "Peer endpoint id is invalid."
            )
        case .noEndpoint:
            PasteBuddyLocalization.string(
                "error.iroh.no_endpoint",
                defaultValue: "Iroh endpoint is not ready."
            )
        case .noSession:
            PasteBuddyLocalization.string(
                "error.iroh.no_session",
                defaultValue: "No active iroh clipboard session."
            )
        case .invalidFrame:
            PasteBuddyLocalization.string(
                "error.iroh.invalid_frame",
                defaultValue: "Iroh clipboard frame is invalid."
            )
        case .frameTooLarge(let byteCount):
            PasteBuddyLocalization.format(
                "error.iroh.frame_too_large",
                defaultValue: "Iroh clipboard frame is too large: %d bytes.",
                byteCount
            )
        case .unsupportedEnvelopeVersion(let version):
            PasteBuddyLocalization.format(
                "error.iroh.unsupported_envelope_version",
                defaultValue: "Iroh clipboard envelope version %d is unsupported.",
                version
            )
        case .keychainReadFailed(let status):
            PasteBuddyLocalization.format(
                "error.iroh.keychain_read_failed",
                defaultValue: "Iroh identity Keychain read failed with status %d.",
                status
            )
        case .keychainWriteFailed(let status):
            PasteBuddyLocalization.format(
                "error.iroh.keychain_write_failed",
                defaultValue: "Iroh identity Keychain write failed with status %d.",
                status
            )
        case .invalidSecretKey:
            PasteBuddyLocalization.string(
                "error.iroh.invalid_secret_key",
                defaultValue: "Stored iroh identity is invalid."
            )
        }
    }
}

struct IrohClipboardSessionState {
    private(set) var currentToken: UUID?

    mutating func beginSession(token: UUID = UUID()) -> UUID {
        currentToken = token
        return token
    }

    mutating func closeSession(token: UUID) -> Bool {
        guard currentToken == token else { return false }
        currentToken = nil
        return true
    }

    mutating func reset() {
        currentToken = nil
    }
}

@MainActor
final class IrohClipboardStartGate {
    private struct InFlight {
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private var inFlight: InFlight?

    func run(
        generation: UInt64 = 0,
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) async {
        while let current = inFlight {
            await current.task.value
            if inFlight?.generation == current.generation {
                inFlight = nil
            }
            if current.generation == generation {
                return
            }
        }

        let task = Task { @MainActor in
            await operation()
        }
        inFlight = InFlight(generation: generation, task: task)
        await task.value
        if inFlight?.generation == generation {
            inFlight = nil
        }
    }
}

protocol IrohClipboardSessionTransport: AnyObject, Sendable {
    func start()
    func stop()
    func send(_ envelope: IrohClipboardSyncEnvelope) async throws
}

struct IrohClipboardPendingSession: Sendable {
    let remoteEndpointID: String
    let openTransport: @MainActor @Sendable (
        @escaping @Sendable (IrohClipboardSyncEnvelope) async -> Void,
        @escaping @Sendable () -> Void
    ) async throws -> any IrohClipboardSessionTransport
}

struct IrohClipboardBoundEndpoint: Sendable {
    let endpointID: String
    let acceptPendingSession: @MainActor @Sendable () async throws -> IrohClipboardPendingSession?
    let connectPendingSession: @MainActor @Sendable (EndpointId) async throws -> IrohClipboardPendingSession
    let close: @MainActor @Sendable () async throws -> Void
}

typealias IrohClipboardEndpointBinder = @MainActor @Sendable () async throws -> IrohClipboardBoundEndpoint

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

    @ObservationIgnored public var onItemReceived: (@MainActor (ClipboardItem) async -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let endpointBinder: IrohClipboardEndpointBinder
    @ObservationIgnored private var endpoint: IrohClipboardBoundEndpoint?
    @ObservationIgnored private var acceptTask: Task<Void, Never>?
    @ObservationIgnored private var currentSession: (any IrohClipboardSessionTransport)?
    @ObservationIgnored private var sessionState = IrohClipboardSessionState()
    @ObservationIgnored private let startGate = IrohClipboardStartGate()
    @ObservationIgnored private var lifecycleGeneration: UInt64 = 0

    private static let peerEndpointDefaultsKey = "pastebuddy.iroh.peerEndpointId"
    nonisolated private static let pairingScheme = "pastebuddy"
    nonisolated private static let pairingHost = "iroh-pair"
    private static let logger = Logger(
        subsystem: "com.alexjiang.PasteBuddy",
        category: "IrohClipboardSync"
    )

    public init(
        defaults: UserDefaults = .standard,
        identityStore: IrohClipboardIdentityStore = .standard
    ) {
        self.defaults = defaults
        self.endpointBinder = {
            try await Self.makeLiveEndpoint(identityStore: identityStore)
        }
        self.peerEndpointId = defaults.string(forKey: Self.peerEndpointDefaultsKey) ?? ""
    }

    init(
        defaults: UserDefaults,
        endpointBinder: @escaping IrohClipboardEndpointBinder
    ) {
        self.defaults = defaults
        self.endpointBinder = endpointBinder
        self.peerEndpointId = defaults.string(forKey: Self.peerEndpointDefaultsKey) ?? ""
    }

    deinit {
        acceptTask?.cancel()
        currentSession?.stop()
    }

    public func start() async {
        guard endpoint == nil else { return }
        let generation = lifecycleGeneration
        await startGate.run(generation: generation) { [weak self] in
            await self?.bindEndpoint(generation: generation)
        }
    }

    public func stop() async {
        lifecycleGeneration &+= 1

        let taskToAwait = acceptTask
        acceptTask = nil
        taskToAwait?.cancel()
        currentSession?.stop()
        currentSession = nil
        sessionState.reset()
        onItemReceived = nil

        let activeEndpoint = endpoint
        endpoint = nil
        endpointId = ""
        var closeFailure: Error?
        if let activeEndpoint {
            do {
                try await activeEndpoint.close()
            } catch {
                closeFailure = error
            }
        }
        if let taskToAwait {
            await taskToAwait.value
        }
        if let closeFailure {
            connectionState = .failed(closeFailure.localizedDescription)
        } else {
            connectionState = .idle
        }
    }

    private func bindEndpoint(generation: UInt64) async {
        guard isCurrent(generation), endpoint == nil else { return }
        let interval = PasteBuddyPerformanceSignposts.begin(.irohEndpointBind)
        connectionState = .binding
        do {
            let boundEndpoint = try await endpointBinder()
            guard isCurrent(generation), !Task.isCancelled else {
                await closeStaleEndpoint(boundEndpoint)
                PasteBuddyPerformanceSignposts.end(interval, result: .cancelled)
                return
            }
            endpointId = boundEndpoint.endpointID
            endpoint = boundEndpoint
            connectionState = .ready
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runAcceptLoop(
                    endpoint: boundEndpoint,
                    generation: generation
                )
            }
            acceptTask = task
            PasteBuddyPerformanceSignposts.end(interval, result: .succeeded)
        } catch {
            guard isCurrent(generation), !Task.isCancelled else {
                PasteBuddyPerformanceSignposts.end(interval, result: .cancelled)
                return
            }
            connectionState = .failed(error.localizedDescription)
            PasteBuddyPerformanceSignposts.end(interval, result: .failed)
        }
    }

    public func connectToPeer() async {
        let generation = lifecycleGeneration
        await start()
        guard isCurrent(generation), !Task.isCancelled else { return }
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
        do {
            let pendingSession = try await endpoint.connectPendingSession(peerId)
            guard isCurrent(generation), !Task.isCancelled else { return }
            try await openAndAdopt(
                pendingSession,
                generation: generation
            )
        } catch {
            guard isCurrent(generation), !Task.isCancelled else { return }
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
                markSendFailure(error)
                return false
            }
            guard item.payload.rtfData != nil || item.payload.imageData != nil else {
                markSendFailure(error)
                return false
            }
            let slimmedItem = Self.slimmedItemForFrameRetry(from: item)
            do {
                try await transport(IrohClipboardSyncEnvelope(item: slimmedItem))
                lastSentAt = Date()
                return true
            } catch let retryError as IrohClipboardSyncError {
                markSendFailure(retryError)
                return false
            } catch let retryError {
                markSendFailure(retryError)
                return false
            }
        } catch {
            markSendFailure(error)
            return false
        }
    }

    public func sendIfConnected(_ item: ClipboardItem) async {
        guard currentSession != nil else { return }
        _ = await send(item)
    }

    public func reportReceivePersistenceFailure(_ error: any Error) {
        currentSession?.stop()
        currentSession = nil
        connectionState = .failed(error.localizedDescription)
    }

    private func runAcceptLoop(
        endpoint: IrohClipboardBoundEndpoint,
        generation: UInt64
    ) async {
        while isCurrent(generation), !Task.isCancelled {
            do {
                guard let pendingSession = try await endpoint.acceptPendingSession() else { return }
                guard isCurrent(generation), !Task.isCancelled else { return }
                guard authorizeIncomingPeer(pendingSession.remoteEndpointID) else { continue }
                try await openAndAdopt(
                    pendingSession,
                    generation: generation
                )
            } catch {
                guard isCurrent(generation), !Task.isCancelled else { return }
                continue
            }
        }
    }

    func authorizeIncomingPeer(_ remoteEndpointId: String) -> Bool {
        guard let canonicalRemote = Self.canonicalEndpointId(remoteEndpointId) else { return false }
        let configuredPeer = peerEndpointId.trimmingCharacters(in: .whitespacesAndNewlines)
        if configuredPeer.isEmpty {
            peerEndpointId = canonicalRemote
            return true
        }
        guard Self.canonicalEndpointId(configuredPeer) == canonicalRemote else { return false }
        peerEndpointId = canonicalRemote
        return true
    }

    nonisolated private static func canonicalEndpointId(_ endpointId: String) -> String? {
        let trimmed = endpointId.trimmingCharacters(in: .whitespacesAndNewlines)
        return try? EndpointId.fromString(s: trimmed).description
    }

    private func openAndAdopt(
        _ pendingSession: IrohClipboardPendingSession,
        generation: UInt64
    ) async throws {
        let sessionToken = UUID()
        let session = try await pendingSession.openTransport(
            { [weak self] envelope in
                await self?.receive(envelope)
            },
            { [weak self] in
                Task { @MainActor in
                    self?.handleSessionClosed(token: sessionToken)
                }
            }
        )
        guard isCurrent(generation), !Task.isCancelled else {
            session.stop()
            return
        }

        _ = sessionState.beginSession(token: sessionToken)
        currentSession?.stop()
        currentSession = session
        session.start()
        connectionState = .connected(
            peerShortId: String(pendingSession.remoteEndpointID.prefix(10))
        )
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        lifecycleGeneration == generation
    }

    private func closeStaleEndpoint(_ endpoint: IrohClipboardBoundEndpoint) async {
        do {
            try await endpoint.close()
        } catch {
            Self.logger.error("Failed to close a stale Iroh endpoint.")
        }
    }

    private static func makeLiveEndpoint(
        identityStore: IrohClipboardIdentityStore
    ) async throws -> IrohClipboardBoundEndpoint {
        let identityInterval = PasteBuddyPerformanceSignposts.begin(.irohIdentityLoad)
        let identity: IrohClipboardIdentity
        do {
            identity = try identityStore.loadOrCreate()
            PasteBuddyPerformanceSignposts.end(identityInterval, result: .succeeded)
        } catch {
            PasteBuddyPerformanceSignposts.end(identityInterval, result: .failed)
            throw error
        }
        let endpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: presetN0(),
            secretKey: identity.secretKey.toBytes(),
            alpns: [IrohClipboardWireFormat.alpn]
        ))

        return IrohClipboardBoundEndpoint(
            endpointID: identity.endpointId,
            acceptPendingSession: {
                while !Task.isCancelled {
                    guard let incoming = await endpoint.acceptNext() else { return nil }
                    do {
                        let accepting = try await incoming.accept()
                        guard try await accepting.alpn() == IrohClipboardWireFormat.alpn else {
                            continue
                        }
                        let connection = try await accepting.connect()
                        let remoteEndpointID = connection.remoteId().description
                        return IrohClipboardPendingSession(
                            remoteEndpointID: remoteEndpointID,
                            openTransport: { receive, closed in
                                let stream = try await connection.acceptBi()
                                return IrohClipboardSession(
                                    stream: stream,
                                    onEnvelopeReceived: receive,
                                    onClosed: closed
                                )
                            }
                        )
                    } catch {
                        guard !Task.isCancelled else { return nil }
                        continue
                    }
                }
                return nil
            },
            connectPendingSession: { peerID in
                let address = EndpointAddr(id: peerID, relayUrl: nil, addresses: [])
                let connection = try await endpoint.connect(
                    addr: address,
                    alpn: IrohClipboardWireFormat.alpn
                )
                return IrohClipboardPendingSession(
                    remoteEndpointID: peerID.description,
                    openTransport: { receive, closed in
                        let stream = try await connection.openBi()
                        return IrohClipboardSession(
                            stream: stream,
                            onEnvelopeReceived: receive,
                            onClosed: closed
                        )
                    }
                )
            },
            close: {
                try await endpoint.close()
            }
        )
    }

    var hasBoundEndpointForTesting: Bool { endpoint != nil }
    var hasActiveSessionForTesting: Bool { currentSession != nil }

    private func receive(_ envelope: IrohClipboardSyncEnvelope) async {
        lastReceivedAt = envelope.sentAt
        lastReceivedTitle = envelope.item.title
        await onItemReceived?(envelope.item)
    }

    private func handleSessionClosed(token: UUID) {
        guard sessionState.closeSession(token: token) else { return }
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

    private func markSendFailure(_ error: any Error) {
        connectionState = .failed(error.localizedDescription)
    }
}

public struct IrohClipboardIdentity: Sendable {
    public let secretKey: SecretKey
    public let endpointId: String
}

struct IrohClipboardKeychainClient: @unchecked Sendable {
    let copyMatching: ([String: Any]) -> (status: OSStatus, data: Data?)
    let add: ([String: Any]) -> OSStatus

    static let live = IrohClipboardKeychainClient(
        copyMatching: { query in
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            return (status, item as? Data)
        },
        add: { query in
            SecItemAdd(query as CFDictionary, nil)
        }
    )
}

public final class IrohClipboardIdentityStore: @unchecked Sendable {
    public static let standard = IrohClipboardIdentityStore()

    private let service: String
    private let account: String
    private let accessGroup: String?
    private let keychainClient: IrohClipboardKeychainClient

    public convenience init(
        service: String = "com.alexjiang.PasteBuddy.iroh",
        account: String = "clipboard-sync-secret-key",
        accessGroup: String? = nil
    ) {
        self.init(
            service: service,
            account: account,
            accessGroup: accessGroup,
            keychainClient: .live
        )
    }

    init(
        service: String,
        account: String,
        accessGroup: String?,
        keychainClient: IrohClipboardKeychainClient
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
        self.keychainClient = keychainClient
    }

    public func loadOrCreate() throws -> IrohClipboardIdentity {
        if let stored = try load(query: baseQuery()) {
            return stored
        }
        if accessGroup != nil,
           let legacyIdentity = try load(query: legacyBaseQuery()) {
            // A query without kSecAttrAccessGroup is not a precise "legacy"
            // selector: it can match any access group available to this app.
            // Keep the old entry after copying so we never delete the new
            // shared-group winner through an unscoped query.
            return try insertOrLoadWinner(secretKey: legacyIdentity.secretKey)
        }
        let secretKey = SecretKey.generate()
        return try insertOrLoadWinner(secretKey: secretKey)
    }

    private func load(query baseQuery: [String: Any]) throws -> IrohClipboardIdentity? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        let result = keychainClient.copyMatching(query)
        let status = result.status
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw IrohClipboardSyncError.keychainReadFailed(status)
        }
        guard let data = result.data,
              let secretKey = try? SecretKey.fromBytes(bytes: data) else {
            throw IrohClipboardSyncError.invalidSecretKey
        }
        return IrohClipboardIdentity(secretKey: secretKey, endpointId: secretKey.public().description)
    }

    private func insertOrLoadWinner(secretKey: SecretKey) throws -> IrohClipboardIdentity {
        var query = baseQuery()
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecValueData as String] = secretKey.toBytes()
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        let status = keychainClient.add(query)
        if status == errSecDuplicateItem {
            return try loadDuplicateWinner()
        }
        guard status == errSecSuccess else {
            throw IrohClipboardSyncError.keychainWriteFailed(status)
        }
        return IrohClipboardIdentity(secretKey: secretKey, endpointId: secretKey.public().description)
    }

    private func loadDuplicateWinner() throws -> IrohClipboardIdentity {
        guard let identity = try load(query: baseQuery()) else {
            throw IrohClipboardSyncError.keychainReadFailed(errSecItemNotFound)
        }
        return identity
    }

    func baseQuery() -> [String: Any] {
        baseQuery(accessGroup: accessGroup)
    }

    private func legacyBaseQuery() -> [String: Any] {
        baseQuery(accessGroup: nil)
    }

    private func baseQuery(accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

enum IrohClipboardReceiveLoop {
    static func run(
        readExact: @Sendable (UInt32) async throws -> Data,
        onEnvelopeReceived: @Sendable (IrohClipboardSyncEnvelope) async -> Void,
        onClosed: @Sendable () -> Void
    ) async {
        while !Task.isCancelled {
            do {
                let lengthPrefix = try await readExact(UInt32(MemoryLayout<UInt32>.size))
                let byteCount = lengthPrefix.withUnsafeBytes { rawBuffer in
                    UInt32(littleEndian: rawBuffer.loadUnaligned(as: UInt32.self))
                }
                guard byteCount <= IrohClipboardWireFormat.maxFrameBytes else {
                    break
                }
                let body = try await readExact(byteCount)
                let envelope = try IrohClipboardWireFormat.decode(lengthPrefix: lengthPrefix, body: body)
                await onEnvelopeReceived(envelope)
            } catch {
                break
            }
        }
        onClosed()
    }
}

private final class IrohClipboardSession: IrohClipboardSessionTransport, @unchecked Sendable {
    private let stream: BiStream
    private let sender: IrohClipboardSender
    private let onEnvelopeReceived: @Sendable (IrohClipboardSyncEnvelope) async -> Void
    private let onClosed: @Sendable () -> Void
    private var receiveTask: Task<Void, Never>?

    init(
        stream: BiStream,
        onEnvelopeReceived: @escaping @Sendable (IrohClipboardSyncEnvelope) async -> Void,
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
        await IrohClipboardReceiveLoop.run(
            readExact: { try await receiver.readExact(size: $0) },
            onEnvelopeReceived: onEnvelopeReceived,
            onClosed: onClosed
        )
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
