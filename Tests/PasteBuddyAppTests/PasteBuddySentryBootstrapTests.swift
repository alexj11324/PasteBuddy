import XCTest
@testable import PasteBuddy

@MainActor
final class PasteBuddySentryBootstrapTests: XCTestCase {
    func testConfigurationIsNilWithoutDSN() {
        XCTAssertNil(
            PasteBuddySentryConfiguration.make(
                infoDictionary: [:],
                environment: [:]
            )
        )
    }

    func testConfigurationPrefersEnvironmentDSNAndTrimsWhitespace() throws {
        let configuration = try XCTUnwrap(
            PasteBuddySentryConfiguration.make(
                infoDictionary: [
                    "PasteBuddySentryDSN": "https://bundle@example.sentry.io/1",
                    "PasteBuddySigningChannel": "release",
                    "CFBundleIdentifier": "com.alexjiang.PasteBuddy",
                    "CFBundleShortVersionString": "1.2.3"
                ],
                environment: [
                    "PASTEBUDDY_SENTRY_DSN": "  https://env@example.sentry.io/2  ",
                    "PASTEBUDDY_SENTRY_ENVIRONMENT": "staging"
                ]
            )
        )

        XCTAssertEqual(configuration.dsn, "https://env@example.sentry.io/2")
        XCTAssertEqual(configuration.environment, "staging")
        XCTAssertEqual(configuration.releaseName, "com.alexjiang.PasteBuddy@1.2.3")
        XCTAssertFalse(configuration.debug)
    }

    func testConfigurationReadsInfoDictionaryAndDefaultsDevelopmentEnvironment() throws {
        let configuration = try XCTUnwrap(
            PasteBuddySentryConfiguration.make(
                infoDictionary: [
                    "PasteBuddySentryDSN": "https://bundle@example.sentry.io/1",
                    "PasteBuddySigningChannel": "development",
                    "CFBundleIdentifier": "com.alexjiang.PasteBuddy.dev",
                    "CFBundleVersion": "42"
                ],
                environment: [:]
            )
        )

        XCTAssertEqual(configuration.dsn, "https://bundle@example.sentry.io/1")
        XCTAssertEqual(configuration.environment, "development")
        XCTAssertEqual(configuration.releaseName, "com.alexjiang.PasteBuddy.dev@42")
        XCTAssertTrue(configuration.debug)
    }

    func testBootstrapStartsOnlyOnceWhenConfigured() {
        let configuration = PasteBuddySentryConfiguration(
            dsn: "https://dsn@example.sentry.io/1",
            environment: "production",
            releaseName: "com.alexjiang.PasteBuddy@1.0",
            debug: false
        )
        var startedConfigurations: [PasteBuddySentryConfiguration] = []

        PasteBuddySentryBootstrap.resetForTesting()
        defer { PasteBuddySentryBootstrap.resetForTesting() }

        XCTAssertEqual(
            PasteBuddySentryBootstrap.startIfConfigured(configuration: configuration) {
                startedConfigurations.append($0)
            },
            .started
        )
        XCTAssertEqual(
            PasteBuddySentryBootstrap.startIfConfigured(configuration: configuration) {
                startedConfigurations.append($0)
            },
            .alreadyStarted
        )

        XCTAssertEqual(startedConfigurations, [configuration])
    }
}
