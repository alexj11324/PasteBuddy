import Foundation
import PasteBuddyCore
import XCTest
@testable import PasteBuddy

@MainActor
final class PasteBuddyMCPHTTPServerTests: XCTestCase {
    func testHTTPParserRejectsAmbiguousOrOversizedBodies() {
        let requests = [
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:18789\r\nContent-Length: -1\r\n\r\n",
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:18789\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:18789\r\nTransfer-Encoding: chunked\r\n\r\n",
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:18789\r\nContent-Length: 18446744073709551616\r\n\r\n",
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:18789\r\nContent-Length: 1048577\r\n\r\n"
        ]

        XCTAssertEqual(
            requests.map { PasteBuddyMCPHTTPServer.rejectionStatus(forHTTPRequest: Data($0.utf8)) },
            [413, 400, 400, 413, 413]
        )
    }

    func testLoopbackHTTPServerHandlesMCPUsingLiveStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasteBuddyMCPHTTPServerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PasteBuddyStore(
            diskStore: EncryptedSnapshotStore(
                fileURL: directory.appendingPathComponent("clipboard.pbstore"),
                storageMode: .standard
            ),
            saveDebounceNanoseconds: nil
        )
        store.setMCPServerEnabled(true)
        _ = store.addCapturedItem(ClipboardItem(
            sourceAppName: "Notes",
            deviceName: "Test Mac",
            contentType: .text,
            title: "HTTP live item",
            payload: ClipboardPayload(text: "HTTP live payload")
        ))
        let token = Data(repeating: 0xA5, count: 32)
        let tokenProvider = FixedMCPTokenProvider(token: token)
        let server = PasteBuddyMCPHTTPServer(
            port: 0,
            tokenProvider: tokenProvider
        )
        server.start(store: store)
        defer { server.stop() }

        for _ in 0..<100 where server.status != .listening {
            try await Task.sleep(for: .milliseconds(20))
        }
        let port = try XCTUnwrap(server.listeningPort)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp"))
        let (_, getResponse) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((getResponse as? HTTPURLResponse)?.statusCode, 405)

        let authenticationURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp/auth"))
        func serverNonce() async throws -> (String, Data) {
            var request = URLRequest(url: authenticationURL)
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let value = try XCTUnwrap(object["serverNonce"] as? String)
            return (value, try XCTUnwrap(Data(base64Encoded: value)))
        }

        let challenge = try MCPAuthenticationToken.randomChallenge()
        var (nonceValue, nonce) = try await serverNonce()
        var authenticationRequest = URLRequest(url: authenticationURL)
        authenticationRequest.httpMethod = "POST"
        authenticationRequest.httpBody = Data("{}".utf8)
        authenticationRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authenticationRequest.setValue(nonceValue, forHTTPHeaderField: "X-PasteBuddy-Server-Nonce")
        authenticationRequest.setValue(
            challenge.base64EncodedString(),
            forHTTPHeaderField: "X-PasteBuddy-Challenge"
        )
        let (_, missingProofResponse) = try await URLSession.shared.data(for: authenticationRequest)
        XCTAssertEqual((missingProofResponse as? HTTPURLResponse)?.statusCode, 401)

        (nonceValue, nonce) = try await serverNonce()
        authenticationRequest.setValue(nonceValue, forHTTPHeaderField: "X-PasteBuddy-Server-Nonce")
        authenticationRequest.setValue("incorrect", forHTTPHeaderField: "X-PasteBuddy-Client-Proof")
        let (_, wrongProofResponse) = try await URLSession.shared.data(for: authenticationRequest)
        XCTAssertEqual((wrongProofResponse as? HTTPURLResponse)?.statusCode, 401)

        (nonceValue, nonce) = try await serverNonce()
        authenticationRequest.setValue(nonceValue, forHTTPHeaderField: "X-PasteBuddy-Server-Nonce")
        authenticationRequest.setValue(
            MCPAuthenticationToken.clientProof(challenge: nonce + challenge, token: token),
            forHTTPHeaderField: "X-PasteBuddy-Client-Proof"
        )
        let (authenticationData, authenticationResponse) = try await URLSession.shared.data(
            for: authenticationRequest
        )
        XCTAssertEqual((authenticationResponse as? HTTPURLResponse)?.statusCode, 200)
        let authenticationObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: authenticationData) as? [String: Any]
        )
        let sessionToken = try XCTUnwrap(authenticationObject["sessionToken"] as? String)
        let sessionData = try XCTUnwrap(Data(base64Encoded: sessionToken))
        XCTAssertEqual(
            authenticationObject["proof"] as? String,
            MCPAuthenticationToken.serverProof(
                challenge: nonce + challenge + sessionData,
                token: token
            )
        )

        let (_, replayedProofResponse) = try await URLSession.shared.data(for: authenticationRequest)
        XCTAssertEqual((replayedProofResponse as? HTTPURLResponse)?.statusCode, 400)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"pastebuddy.search_history","arguments":{"query":"HTTP live"}}}"#.utf8)

        let (_, unauthorizedResponse) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((unauthorizedResponse as? HTTPURLResponse)?.statusCode, 401)

        request.setValue(sessionToken, forHTTPHeaderField: "X-PasteBuddy-Session")
        request.setValue("https://attacker.example", forHTTPHeaderField: "Origin")
        let (_, forbiddenOriginResponse) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((forbiddenOriginResponse as? HTTPURLResponse)?.statusCode, 403)
        request.setValue(nil, forHTTPHeaderField: "Origin")

        request.setValue(sessionToken, forHTTPHeaderField: "X-PasteBuddy-Session")
        let (sessionDataResponse, sessionResponse) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((sessionResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: sessionDataResponse, as: UTF8.self).contains("HTTP live item"))
        let (_, reusedSessionResponse) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((reusedSessionResponse as? HTTPURLResponse)?.statusCode, 401)

        XCTAssertNotNil(server.lastClientActivityAt)
        XCTAssertEqual(store.snapshot.mcp.accessLog.first?.tool, .searchHistory)
        server.revokeAuthenticationToken()
        XCTAssertEqual(tokenProvider.invalidationCount, 1)
    }
}

private final class FixedMCPTokenProvider: MCPAuthenticationTokenProviding, @unchecked Sendable {
    var token: Data
    var invalidationCount = 0

    init(token: Data) {
        self.token = token
    }

    func loadOrCreateToken() throws -> Data { token }
    func invalidateToken() throws { invalidationCount += 1 }
}
