import AppKit
import Foundation

struct InstalledApplication: Identifiable, Hashable, Sendable {
    var url: URL
    var displayName: String
    var bundleIdentifier: String?

    var id: String {
        bundleIdentifier ?? url.standardizedFileURL.path
    }
}

struct InstalledApplicationCatalog: Sendable {
    private static let sharedCache = InstalledApplicationCatalogCache(cacheLifetime: 60)

    let applicationDirectories: [URL]
    private let usesSharedCache: Bool

    init(applicationDirectories: [URL]? = nil) {
        if let applicationDirectories {
            self.applicationDirectories = applicationDirectories
            usesSharedCache = false
        } else {
            self.applicationDirectories = InstalledApplicationCatalog.defaultApplicationDirectories()
            usesSharedCache = true
        }
    }

    private func scanApplications() -> [InstalledApplication] {
        let fileManager = FileManager()
        var seen = Set<String>()
        return applicationDirectories
            .flatMap { applications(in: $0, fileManager: fileManager) }
            .filter { application in
                let key = application.bundleIdentifier ?? application.url.standardizedFileURL.path
                return seen.insert(key).inserted
            }
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    func applications(forceRefresh: Bool = false) async -> [InstalledApplication] {
        let applicationDirectories = applicationDirectories
        let scan: @Sendable () async -> [InstalledApplication] = {
            await Task.detached(priority: .utility) {
                InstalledApplicationCatalog(
                    applicationDirectories: applicationDirectories
                ).scanApplications()
            }.value
        }

        guard usesSharedCache else {
            return await scan()
        }
        return await Self.sharedCache.applications(forceRefresh: forceRefresh, scan: scan)
    }

    private func applications(in directory: URL, fileManager: FileManager) -> [InstalledApplication] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var applications: [InstalledApplication] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame else {
                continue
            }
            if let application = installedApplication(at: url) {
                applications.append(application)
            }
            enumerator.skipDescendants()
        }
        return applications
    }

    private func installedApplication(at url: URL) -> InstalledApplication? {
        let bundle = Bundle(url: url)
        let name = stringValue(bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName"))
            ?? stringValue(bundle?.object(forInfoDictionaryKey: "CFBundleName"))
            ?? url.deletingPathExtension().lastPathComponent
        let bundleIdentifier = stringValue(bundle?.bundleIdentifier)

        return InstalledApplication(
            url: url,
            displayName: name,
            bundleIdentifier: bundleIdentifier
        )
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func defaultApplicationDirectories() -> [URL] {
        let fileManager = FileManager()
        let domains: [FileManager.SearchPathDomainMask] = [.userDomainMask, .localDomainMask, .systemDomainMask]
        let directories = domains.flatMap { fileManager.urls(for: .applicationDirectory, in: $0) }

        var seen = Set<String>()
        return directories.filter { directory in
            seen.insert(directory.standardizedFileURL.path).inserted
        }
    }
}

private actor InstalledApplicationCatalogCache {
    private let cacheLifetime: TimeInterval
    private var cachedApplications: [InstalledApplication]?
    private var cachedAt: Date?
    private var inFlight: Task<[InstalledApplication], Never>?

    init(cacheLifetime: TimeInterval) {
        self.cacheLifetime = cacheLifetime
    }

    func applications(
        forceRefresh: Bool,
        scan: @escaping @Sendable () async -> [InstalledApplication]
    ) async -> [InstalledApplication] {
        if let inFlight {
            return await inFlight.value
        }
        if !forceRefresh {
            let now = Date()
            if let cachedApplications,
               let cachedAt,
               now.timeIntervalSince(cachedAt) < cacheLifetime {
                return cachedApplications
            }
        }

        let task = Task { await scan() }
        inFlight = task
        let applications = await task.value
        cachedApplications = applications
        cachedAt = Date()
        inFlight = nil
        return applications
    }
}
