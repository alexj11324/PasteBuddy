import Foundation

struct InstalledApplication: Identifiable, Hashable {
    var url: URL
    var displayName: String
    var bundleIdentifier: String?

    var id: String {
        bundleIdentifier ?? url.standardizedFileURL.path
    }
}

struct InstalledApplicationCatalog {
    var applicationDirectories: [URL]
    var fileManager: FileManager

    init(
        applicationDirectories: [URL] = InstalledApplicationCatalog.defaultApplicationDirectories(),
        fileManager: FileManager = .default
    ) {
        self.applicationDirectories = applicationDirectories
        self.fileManager = fileManager
    }

    func applications() -> [InstalledApplication] {
        var seen = Set<String>()
        return applicationDirectories
            .flatMap(applications(in:))
            .filter { application in
                let key = application.bundleIdentifier ?? application.url.standardizedFileURL.path
                return seen.insert(key).inserted
            }
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    private func applications(in directory: URL) -> [InstalledApplication] {
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

    private static func defaultApplicationDirectories(fileManager: FileManager = .default) -> [URL] {
        let domains: [FileManager.SearchPathDomainMask] = [.userDomainMask, .localDomainMask, .systemDomainMask]
        var directories = domains.flatMap { fileManager.urls(for: .applicationDirectory, in: $0) }
        directories += directories.map { $0.appendingPathComponent("Utilities", isDirectory: true) }

        var seen = Set<String>()
        return directories.filter { directory in
            seen.insert(directory.standardizedFileURL.path).inserted
        }
    }
}
