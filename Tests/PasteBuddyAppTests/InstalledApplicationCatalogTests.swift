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

    func testCatalogDeclaresBackgroundSharedTTLCacheAndSingleFlight() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Models/InstalledApplicationCatalog.swift")

        XCTAssertTrue(source.contains("func applications(forceRefresh: Bool = false) async"))
        XCTAssertTrue(source.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(source.contains("private static let sharedCache"))
        XCTAssertTrue(source.contains("private actor InstalledApplicationCatalogCache"))
        XCTAssertTrue(source.contains("cacheLifetime"))
        XCTAssertTrue(source.contains("inFlight"))
        XCTAssertTrue(source.contains("guard usesSharedCache else"))
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

    func testSettingsLoadsInstalledApplicationsAsynchronouslyAtEveryEntryPoint() throws {
        let source = try sourceFileContents("Sources/PasteBuddy/Views/SettingsView.swift")
        let catalogCallLines = source.split(separator: "\n").filter {
            $0.contains("InstalledApplicationCatalog().applications")
        }

        XCTAssertEqual(catalogCallLines.count, 3)
        XCTAssertTrue(catalogCallLines.allSatisfy { $0.contains("await ") })
    }

    func testExplicitSettingsRefreshBypassesFreshCatalogCache() throws {
        let catalogSource = try sourceFileContents("Sources/PasteBuddy/Models/InstalledApplicationCatalog.swift")
        let settingsSource = try sourceFileContents("Sources/PasteBuddy/Views/SettingsView.swift")

        XCTAssertTrue(catalogSource.contains("func applications(forceRefresh: Bool = false) async"))
        XCTAssertTrue(catalogSource.contains("forceRefresh: forceRefresh"))
        XCTAssertTrue(settingsSource.contains("reloadMCPClientCandidates(forceRefresh: true)"))
        XCTAssertTrue(
            settingsSource.contains(
                "await InstalledApplicationCatalog().applications(forceRefresh: forceRefresh)"
            )
        )
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

    private func sourceFileContents(_ relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return String(decoding: try Data(contentsOf: candidate), as: UTF8.self)
            }
            directory.deleteLastPathComponent()
        }
        throw XCTSkip("Could not locate \(relativePath) from \(FileManager.default.currentDirectoryPath)")
    }
}
