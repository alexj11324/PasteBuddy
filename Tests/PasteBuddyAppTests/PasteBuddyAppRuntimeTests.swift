import XCTest
@testable import PasteBuddy

@MainActor
final class PasteBuddyAppRuntimeTests: XCTestCase {
    func testRuntimeLoadGateInvokesAsyncLoadOnlyOnce() async {
        let gate = PasteBuddyRuntimeLoadGate()
        var loadAsyncCallCount = 0

        await gate.loadIfNeeded {
            loadAsyncCallCount += 1
        }
        await gate.loadIfNeeded {
            loadAsyncCallCount += 1
        }

        XCTAssertEqual(loadAsyncCallCount, 1)
    }

    func testLifecycleFlushForTerminationTriggersPendingSaveFlush() {
        var didFlush = false

        PasteBuddyLifecycleFlush.flushForTermination({
            didFlush = true
        }, timeout: 0.05)

        XCTAssertTrue(didFlush)
    }
}
