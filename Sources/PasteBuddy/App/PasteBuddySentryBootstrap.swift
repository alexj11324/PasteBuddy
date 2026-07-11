import Foundation
import Sentry

struct PasteBuddySentryConfiguration: Equatable, Sendable {
    let dsn: String
    let environment: String
    let releaseName: String?
    let debug: Bool

    static func make(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PasteBuddySentryConfiguration? {
        guard let dsn = firstNonEmptyValue(
            environment["PASTEBUDDY_SENTRY_DSN"],
            environment["SENTRY_DSN"],
            infoDictionary["PasteBuddySentryDSN"] as? String,
            infoDictionary["SentryDSN"] as? String
        ) else {
            return nil
        }

        let signingChannel = trimmed(infoDictionary["PasteBuddySigningChannel"] as? String)
        let sentryEnvironment = firstNonEmptyValue(
            environment["PASTEBUDDY_SENTRY_ENVIRONMENT"],
            infoDictionary["PasteBuddySentryEnvironment"] as? String
        ) ?? defaultEnvironment(signingChannel: signingChannel)

        return PasteBuddySentryConfiguration(
            dsn: dsn,
            environment: sentryEnvironment,
            releaseName: releaseName(infoDictionary: infoDictionary),
            debug: sentryEnvironment == "development"
        )
    }

    private static func firstNonEmptyValue(_ values: String?...) -> String? {
        values.lazy.compactMap(trimmed).first
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private static func defaultEnvironment(signingChannel: String?) -> String {
        signingChannel == "release" ? "production" : "development"
    }

    private static func releaseName(infoDictionary: [String: Any]) -> String? {
        guard let bundleIdentifier = trimmed(infoDictionary["CFBundleIdentifier"] as? String) else {
            return nil
        }
        guard let version = firstNonEmptyValue(
            infoDictionary["CFBundleShortVersionString"] as? String,
            infoDictionary["CFBundleVersion"] as? String
        ) else {
            return bundleIdentifier
        }
        return "\(bundleIdentifier)@\(version)"
    }
}

enum PasteBuddySentryStartResult: Equatable {
    case notConfigured
    case started
    case alreadyStarted
}

@MainActor
enum PasteBuddySentryBootstrap {
    private static var didStart = false

    static func startIfConfigured(
        configuration: PasteBuddySentryConfiguration? = PasteBuddySentryConfiguration.make(),
        start: @MainActor (PasteBuddySentryConfiguration) -> Void = startSentry
    ) -> PasteBuddySentryStartResult {
        guard let configuration else {
            return .notConfigured
        }
        guard !didStart else {
            return .alreadyStarted
        }

        start(configuration)
        didStart = true
        return .started
    }

    static func resetForTesting() {
        didStart = false
    }

    private static func startSentry(configuration: PasteBuddySentryConfiguration) {
        SentrySDK.start { options in
            configure(options: options, configuration: configuration)
        }
    }

    static func configure(options: Options, configuration: PasteBuddySentryConfiguration) {
        options.dsn = configuration.dsn
        options.environment = configuration.environment
        options.releaseName = configuration.releaseName
        options.debug = configuration.debug
        options.sendDefaultPii = false
        options.enableAutoBreadcrumbTracking = false
        options.enableNetworkBreadcrumbs = false
        options.enableNetworkTracking = false
        options.enableAutoSessionTracking = false
        options.attachStacktrace = false
        options.enableAutoPerformanceTracing = false
        options.enableFileIOTracing = false
        options.enableDataSwizzling = false
        options.enableFileManagerSwizzling = false
        options.enableLogs = false
        options.tracesSampleRate = 0
        options.beforeSend = { event in
            event.extra = nil
            event.breadcrumbs = nil
            return event
        }
    }
}
