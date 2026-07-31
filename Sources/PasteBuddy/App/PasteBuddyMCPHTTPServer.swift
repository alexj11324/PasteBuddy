import Foundation
import Network
import Observation
import PasteBuddyCore

@MainActor
@Observable
final class PasteBuddyMCPHTTPServer {
    static let endpoint = "http://127.0.0.1:18789/mcp"
    private static let maximumHeaderBytes = 65_536
    private static let maximumBodyBytes = 1_048_576

    enum Status: Equatable {
        case stopped
        case starting
        case listening
        case failed(String)
    }

    private(set) var status: Status = .stopped
    private(set) var lastClientActivityAt: Date?
    private(set) var listeningPort: UInt16?
    private(set) var configurationToken: String?

    private let configuredPort: UInt16
    private let tokenProvider: any MCPAuthenticationTokenProviding
    private var listener: NWListener?
    private var service: MCPJSONRPCService?
    private var authenticationToken: Data?
    private var authenticationNonces: [String: Date] = [:]
    private var sessionTokens: [String: Date] = [:]
    private let queue = DispatchQueue(label: "com.alexjiang.PasteBuddy.mcp-http")

    init(
        port: UInt16 = 18_789,
        tokenProvider: any MCPAuthenticationTokenProviding = KeychainMCPAuthenticationTokenStore()
    ) {
        configuredPort = port
        self.tokenProvider = tokenProvider
    }

    func start(store: PasteBuddyStore) {
        guard listener == nil else { return }
        do {
            let token = try tokenProvider.loadOrCreateToken()
            guard token.count == 32 else { throw EncryptionServiceError.invalidKeyMaterial }
            let parameters = NWParameters.tcp
            let port = configuredPort == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: configuredPort)!
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            service = MCPJSONRPCService(store: store)
            authenticationToken = token
            configurationToken = MCPAuthenticationToken.encoded(token)
            status = .starting
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handleListenerState(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: queue)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        service = nil
        authenticationToken = nil
        authenticationNonces.removeAll()
        sessionTokens.removeAll()
        configurationToken = nil
        listeningPort = nil
        status = .stopped
    }

    func revokeAuthenticationToken() {
        stop()
        do {
            try tokenProvider.invalidateToken()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            listeningPort = listener?.port?.rawValue
            status = .listening
        case .failed(let error):
            listener = nil
            service = nil
            authenticationToken = nil
            authenticationNonces.removeAll()
            sessionTokens.removeAll()
            configurationToken = nil
            listeningPort = nil
            status = .failed(error.localizedDescription)
        case .cancelled:
            if listener == nil { status = .stopped }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumBodyBytes) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else {
                    connection.cancel()
                    return
                }
                var request = accumulated
                if let data { request.append(data) }
                if request.count > Self.maximumHeaderBytes + Self.maximumBodyBytes {
                    self.send(Self.httpResponse(status: 413, body: nil), on: connection)
                    return
                }
                switch Self.parseRequest(request) {
                case .request(let parsed):
                    await self.respond(to: parsed, on: connection)
                case .rejected(let status):
                    self.send(Self.httpResponse(status: status, body: nil), on: connection)
                case .incomplete where isComplete || error != nil:
                    self.send(Self.httpResponse(status: 400, body: nil), on: connection)
                case .incomplete:
                    self.receive(on: connection, accumulated: request)
                }
            }
        }
    }

    private func respond(to request: Request, on connection: NWConnection) async {
        guard request.path == "/mcp" || request.path == "/mcp/auth" else {
            send(Self.httpResponse(status: 404, body: nil), on: connection)
            return
        }
        guard request.method == "POST" else {
            send(Self.httpResponse(status: 405, body: nil), on: connection)
            return
        }
        guard request.headers["host"] == expectedHost else {
            send(Self.httpResponse(status: 403, body: nil), on: connection)
            return
        }
        guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
            send(Self.httpResponse(status: 415, body: nil), on: connection)
            return
        }
        guard Self.isAllowedOrigin(request.headers["origin"], expectedHost: expectedHost) else {
            send(Self.httpResponse(status: 403, body: nil), on: connection)
            return
        }
        if request.path == "/mcp/auth" {
            guard let token = authenticationToken else {
                send(Self.httpResponse(status: 503, body: nil), on: connection)
                return
            }
            if request.headers["x-pastebuddy-server-nonce"] == nil,
               request.headers["x-pastebuddy-challenge"] == nil,
               request.headers["x-pastebuddy-client-proof"] == nil {
                guard let nonce = try? MCPAuthenticationToken.randomChallenge(),
                      let body = try? JSONSerialization.data(withJSONObject: [
                          "serverNonce": nonce.base64EncodedString()
                      ]) else {
                    send(Self.httpResponse(status: 503, body: nil), on: connection)
                    return
                }
                Self.storeEphemeralToken(nonce.base64EncodedString(), in: &authenticationNonces)
                send(Self.httpResponse(status: 200, body: body), on: connection)
                return
            }
            guard let nonceValue = request.headers["x-pastebuddy-server-nonce"],
                  let nonce = Data(base64Encoded: nonceValue),
                  nonce.count == 32,
                  Self.consumeEphemeralToken(nonceValue, from: &authenticationNonces),
                  let challengeValue = request.headers["x-pastebuddy-challenge"],
                  let challenge = Data(base64Encoded: challengeValue),
                  challenge.count == 32 else {
                send(Self.httpResponse(status: 400, body: nil), on: connection)
                return
            }
            guard let clientProof = request.headers["x-pastebuddy-client-proof"],
                  MCPAuthenticationToken.constantTimeMatches(
                      clientProof,
                      expected: MCPAuthenticationToken.clientProof(challenge: nonce + challenge, token: token)
                  ) else {
                send(Self.httpResponse(status: 401, body: nil), on: connection)
                return
            }
            guard let sessionData = try? MCPAuthenticationToken.randomChallenge(),
                  sessionData.count == 32,
                  let body = try? JSONSerialization.data(withJSONObject: [
                      "proof": MCPAuthenticationToken.serverProof(
                          challenge: nonce + challenge + sessionData,
                          token: token
                      ),
                      "sessionToken": sessionData.base64EncodedString()
                  ]) else {
                send(Self.httpResponse(status: 400, body: nil), on: connection)
                return
            }
            Self.storeEphemeralToken(sessionData.base64EncodedString(), in: &sessionTokens)
            send(Self.httpResponse(status: 200, body: body), on: connection)
            return
        }
        guard consumeSessionToken(request.headers["x-pastebuddy-session"]) else {
            send(Self.httpResponse(status: 401, body: nil), on: connection)
            return
        }
        guard let service else {
            send(Self.httpResponse(status: 503, body: nil), on: connection)
            return
        }

        lastClientActivityAt = Date()
        let body = await service.handle(request.body)
        send(Self.httpResponse(status: body == nil ? 202 : 200, body: body), on: connection)
    }

    private static func storeEphemeralToken(_ token: String, in storage: inout [String: Date]) {
        let now = Date()
        storage = storage.filter { $0.value > now }
        if storage.count >= 128, let oldest = storage.min(by: { $0.value < $1.value })?.key {
            storage.removeValue(forKey: oldest)
        }
        storage[token] = now.addingTimeInterval(10)
    }

    private static func consumeEphemeralToken(_ candidate: String?, from storage: inout [String: Date]) -> Bool {
        guard let candidate, let expiresAt = storage.removeValue(forKey: candidate) else { return false }
        return expiresAt > Date()
    }

    private func consumeSessionToken(_ candidate: String?) -> Bool {
        Self.consumeEphemeralToken(candidate, from: &sessionTokens)
    }

    private func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private enum RequestParseResult {
        case incomplete
        case rejected(Int)
        case request(Request)
    }

    private static func parseRequest(_ data: Data) -> RequestParseResult {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maximumHeaderBytes ? .rejected(413) : .incomplete
        }
        guard headerRange.lowerBound <= maximumHeaderBytes,
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return .rejected(400)
        }
        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3 else { return .rejected(400) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return .rejected(400) }
            let name = String(parts[0]).lowercased()
            guard headers[name] == nil else { return .rejected(400) }
            headers[name] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { return .rejected(400) }
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty,
              rawLength.allSatisfy(\.isNumber),
              let parsedLength = UInt64(rawLength),
              parsedLength <= UInt64(maximumBodyBytes) else {
            return .rejected(413)
        }
        let contentLength = Int(parsedLength)
        guard data.count >= headerRange.upperBound + contentLength else { return .incomplete }
        let body = data.subdata(in: headerRange.upperBound..<(headerRange.upperBound + contentLength))
        return .request(Request(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            headers: headers,
            body: body
        ))
    }

    static func rejectionStatus(forHTTPRequest data: Data) -> Int? {
        switch parseRequest(data) {
        case .rejected(let status): status
        case .incomplete: 400
        case .request: nil
        }
    }

    private var expectedHost: String {
        "127.0.0.1:\(listeningPort ?? configuredPort)"
    }

    private static func isAllowedOrigin(_ origin: String?, expectedHost: String) -> Bool {
        guard let origin else { return true }
        guard let url = URL(string: origin), url.scheme == "http", url.host == "127.0.0.1",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty else { return false }
        return "127.0.0.1:\(url.port ?? 80)" == expectedHost
    }

    private static func httpResponse(status: Int, body: Data?) -> Data {
        let reason = switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        default: "Service Unavailable"
        }
        let body = body ?? Data()
        let headers = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: application/json\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        return Data(headers.utf8) + body
    }
}
