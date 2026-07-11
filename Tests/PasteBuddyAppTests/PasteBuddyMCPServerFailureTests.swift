import PasteBuddyCore
import XCTest
@testable import PasteBuddyMCP

@MainActor
final class PasteBuddyMCPServerFailureTests: XCTestCase {
    func testCreatePinboardReturnsJSONRPCLoadErrorBeforeMutation() async throws {
        let fixture = try await PersistenceFailureTestFixture.make()
        defer { fixture.cleanup() }
        let loaderProbe = MCPStoreLoaderProbe(store: fixture.store)
        let server = PasteBuddyMCPServer(storeLoader: {
            try await loaderProbe.load()
        })

        let response = await server.handle([
            "jsonrpc": "2.0",
            "id": 42,
            "method": "tools/call",
            "params": [
                "name": MCPToolName.createPinboard.rawValue,
                "arguments": [
                    "name": "Must Not Be Created",
                    "colorHex": "#FF0000"
                ]
            ]
        ])

        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32000)
        XCTAssertEqual(
            error["message"] as? String,
            PasteBuddyPersistenceError.historyUnavailable.localizedDescription
        )
        XCTAssertNil(response["result"])
        XCTAssertEqual(loaderProbe.callCount, 1)
        XCTAssertTrue(fixture.store.isPersistenceWriteBlocked)
        XCTAssertEqual(
            fixture.store.snapshot.items.map(\.id),
            fixture.snapshotItemIDsBeforeFailure
        )
        XCTAssertEqual(
            fixture.store.snapshot.pinboards.map(\.id),
            fixture.snapshotPinboardIDsBeforeFailure
        )
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), fixture.diskBytesBeforeFailure)
    }
}

@MainActor
private final class MCPStoreLoaderProbe {
    let store: PasteBuddyStore
    private(set) var callCount = 0

    init(store: PasteBuddyStore) {
        self.store = store
    }

    func load() async throws -> PasteBuddyStore {
        callCount += 1
        try await PasteBuddyStoreFactory.load(store)
        return store
    }
}
