import Foundation
import XCTest
@testable import PasteBuddy

@MainActor
final class InstalledApplicationCatalogTests: XCTestCase {
    func testDefaultCatalogDoesNotRescanNestedApplicationDirectories() {
        let directories = InstalledApplicationCatalog().applicationDirectories.map(\.standardizedFileURL.path)

        for (index, directory) in directories.enumerated() {
            for (parentIndex, parent) in directories.enumerated() where parentIndex != index {
                XCTAssertFalse(
                    directory.hasPrefix(parent + "/"),
                    "\(directory) is already traversed while enumerating \(parent)"
                )
            }
        }
    }

    func testCustomApplicationDirectoriesBypassSharedCacheDeterministically() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("PasteBuddyInstalledApplicationCatalogTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try makeTemporaryApp(
            at: root.appendingPathComponent("First.app", isDirectory: true),
            displayName: "First",
            bundleIdentifier: "com.example.first"
        )
        let catalog = InstalledApplicationCatalog(applicationDirectories: [root])

        let firstLoad = await catalog.applications()

        try makeTemporaryApp(
            at: root.appendingPathComponent("Second.app", isDirectory: true),
            displayName: "Second",
            bundleIdentifier: "com.example.second"
        )
        let secondLoad = await catalog.applications()

        XCTAssertEqual(firstLoad.map(\.displayName), ["First"])
        XCTAssertEqual(secondLoad.map(\.displayName), ["First", "Second"])
    }

    func testCacheReusesFreshApplicationsUntilForcedRefresh() async {
        let cache = InstalledApplicationCatalogCache(cacheLifetime: 60)
        let probe = InstalledApplicationScanProbe(results: [
            [application(named: "First")],
            [application(named: "Second")]
        ])

        let first = await cache.applications(forceRefresh: false) { await probe.scan() }
        let cached = await cache.applications(forceRefresh: false) { await probe.scan() }
        let refreshed = await cache.applications(forceRefresh: true) { await probe.scan() }
        let callCount = await probe.count()

        XCTAssertEqual(first.map(\.displayName), ["First"])
        XCTAssertEqual(cached.map(\.displayName), ["First"])
        XCTAssertEqual(refreshed.map(\.displayName), ["Second"])
        XCTAssertEqual(callCount, 2)
    }

    func testCacheCoalescesConcurrentApplicationScans() async {
        let cache = InstalledApplicationCatalogCache(cacheLifetime: 60)
        let gate = InstalledApplicationScanGate(result: [application(named: "Shared")])

        async let first = cache.applications(forceRefresh: false) { await gate.scan() }
        async let second = cache.applications(forceRefresh: false) { await gate.scan() }
        await gate.waitUntilStarted()
        let callCountWhileSuspended = await gate.count()

        XCTAssertEqual(callCountWhileSuspended, 1)
        await gate.release()
        let (firstResult, secondResult) = await (first, second)
        let finalCallCount = await gate.count()

        XCTAssertEqual(firstResult, secondResult)
        XCTAssertEqual(firstResult.map(\.displayName), ["Shared"])
        XCTAssertEqual(finalCallCount, 1)
    }

    private func makeTemporaryApp(
        at url: URL,
        displayName: String,
        bundleIdentifier: String
    ) throws {
        let contentsURL = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let info = [
            "CFBundleDisplayName": displayName,
            "CFBundleName": displayName,
            "CFBundleIdentifier": bundleIdentifier
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
    }

    private func application(named name: String) -> InstalledApplication {
        InstalledApplication(
            url: URL(fileURLWithPath: "/Applications/\(name).app"),
            displayName: name,
            bundleIdentifier: "com.example.\(name.lowercased())"
        )
    }
}

private actor InstalledApplicationScanProbe {
    private let results: [[InstalledApplication]]
    private var index = 0

    init(results: [[InstalledApplication]]) {
        self.results = results
    }

    func count() -> Int { index }

    func scan() -> [InstalledApplication] {
        defer { index += 1 }
        return results[min(index, results.index(before: results.endIndex))]
    }
}

private actor InstalledApplicationScanGate {
    private let result: [InstalledApplication]
    private var calls = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    init(result: [InstalledApplication]) {
        self.result = result
    }

    func count() -> Int { calls }

    func scan() async -> [InstalledApplication] {
        calls += 1
        if !isReleased {
            await withCheckedContinuation { continuations.append($0) }
        }
        return result
    }

    func waitUntilStarted() async {
        while continuations.isEmpty { await Task.yield() }
    }

    func release() {
        isReleased = true
        let blocked = continuations
        continuations.removeAll()
        blocked.forEach { $0.resume() }
    }
}
