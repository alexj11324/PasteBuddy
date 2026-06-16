import Foundation

public struct PasteBuddyRuntimeIdentity: Equatable, Sendable {
    public var bundleIdentifier: String
    public var bundlePath: String
    public var executablePath: String
    public var stableAppPath: String
    public var signingChannel: String
    public var codeSigningIdentity: String

    public var isRunningFromStablePath: Bool {
        Self.normalized(bundlePath) == Self.normalized(stableAppPath)
    }

    public init(
        bundleIdentifier: String,
        bundlePath: String,
        executablePath: String,
        stableAppPath: String,
        signingChannel: String,
        codeSigningIdentity: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.stableAppPath = stableAppPath
        self.signingChannel = signingChannel
        self.codeSigningIdentity = codeSigningIdentity
    }

    private static func normalized(_ path: String) -> String {
        guard path != "Unknown" else { return path }
        return URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }
}

public enum PasteBuddyRuntimeIdentityService {
    public static var current: PasteBuddyRuntimeIdentity {
        current(for: .main)
    }

    public static func current(for bundle: Bundle) -> PasteBuddyRuntimeIdentity {
        PasteBuddyRuntimeIdentity(
            bundleIdentifier: bundle.bundleIdentifier ?? "Unknown",
            bundlePath: bundle.bundlePath,
            executablePath: bundle.executablePath ?? "Unknown",
            stableAppPath: bundle.object(forInfoDictionaryKey: "PasteBuddyStableAppPath") as? String ?? "Unknown",
            signingChannel: bundle.object(forInfoDictionaryKey: "PasteBuddySigningChannel") as? String ?? "Unknown",
            codeSigningIdentity: bundle.object(forInfoDictionaryKey: "PasteBuddyCodeSigningIdentity") as? String ?? "Unknown"
        )
    }
}
