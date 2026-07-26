import Foundation
import XCTest
@testable import PasteBuddy

final class HistoryCardTimestampFormatterTests: XCTestCase {
    func testCrossingMidnightUsesDateAndTimeInsteadOfRollingTwentyFourHours() throws {
        let context = try TestContext(
            timeZoneIdentifier: "America/New_York",
            now: DateComponents(year: 2026, month: 1, day: 2, hour: 0, minute: 5)
        )
        let capturedAt = try context.date(
            DateComponents(year: 2026, month: 1, day: 1, hour: 23, minute: 55)
        )

        let presentation = context.formatter.presentation(for: capturedAt)

        XCTAssertEqual(presentation.mode, .dateAndTime)
        XCTAssertEqual(presentation.visibleText, "Jan 1 at 11:55 PM")
    }

    func testCurrentCalendarDayUsesOnlyLocalizedHourAndMinute() throws {
        let context = try TestContext(
            timeZoneIdentifier: "America/New_York",
            now: DateComponents(year: 2026, month: 7, day: 25, hour: 17, minute: 45)
        )
        let capturedAt = try context.date(
            DateComponents(year: 2026, month: 7, day: 25, hour: 8, minute: 7)
        )

        let presentation = context.formatter.presentation(for: capturedAt)

        XCTAssertEqual(presentation.mode, .timeOnly)
        XCTAssertEqual(presentation.visibleText, "8:07 AM")
    }

    func testPreviousCalendarYearIncludesYear() throws {
        let context = try TestContext(
            timeZoneIdentifier: "America/New_York",
            now: DateComponents(year: 2026, month: 1, day: 2, hour: 10)
        )
        let capturedAt = try context.date(
            DateComponents(year: 2025, month: 12, day: 31, hour: 23, minute: 55)
        )

        XCTAssertEqual(
            context.formatter.presentation(for: capturedAt).visibleText,
            "Dec 31, 2025 at 11:55 PM"
        )
    }

    func testSameDayAcrossDSTSpringForwardStillUsesTimeOnly() throws {
        let context = try TestContext(
            timeZoneIdentifier: "America/New_York",
            now: DateComponents(year: 2026, month: 3, day: 8, hour: 3, minute: 30)
        )
        let capturedAt = try context.date(
            DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 30)
        )

        let presentation = context.formatter.presentation(for: capturedAt)

        XCTAssertEqual(presentation.mode, .timeOnly)
        XCTAssertEqual(presentation.visibleText, "1:30 AM")
    }

    func testTimeZoneControlsCalendarDayBoundary() throws {
        let capturedAt = try Date("2026-01-02T07:30:00Z", strategy: .iso8601)
        let now = try Date("2026-01-02T08:30:00Z", strategy: .iso8601)
        let losAngeles = try TestContext(
            timeZoneIdentifier: "America/Los_Angeles",
            now: now
        )
        let tokyo = try TestContext(
            timeZoneIdentifier: "Asia/Tokyo",
            now: now
        )

        XCTAssertEqual(
            losAngeles.formatter.presentation(for: capturedAt).mode,
            .dateAndTime
        )
        XCTAssertEqual(
            tokyo.formatter.presentation(for: capturedAt).mode,
            .timeOnly
        )
    }

    func testLocaleControlsLocalizedHourPresentation() throws {
        let now = try Date("2026-01-02T08:30:00Z", strategy: .iso8601)
        let capturedAt = try Date("2026-01-02T07:30:00Z", strategy: .iso8601)
        let british = try TestContext(
            timeZoneIdentifier: "Asia/Tokyo",
            localeIdentifier: "en_GB",
            now: now
        )

        XCTAssertEqual(
            british.formatter.presentation(for: capturedAt).visibleText,
            "16:30"
        )
    }

    func testAccessibilityTimestampIsFullAndExactInBothVisibleModes() throws {
        let context = try TestContext(
            timeZoneIdentifier: "America/New_York",
            now: DateComponents(year: 2026, month: 11, day: 1, hour: 12)
        )
        let today = try context.date(
            DateComponents(year: 2026, month: 11, day: 1, hour: 1, minute: 30, second: 12)
        )
        let yesterday = try context.date(
            DateComponents(year: 2026, month: 10, day: 31, hour: 23, minute: 59, second: 45)
        )

        let timeOnly = context.formatter.presentation(for: today)
        let dateAndTime = context.formatter.presentation(for: yesterday)

        XCTAssertEqual(timeOnly.mode, .timeOnly)
        XCTAssertEqual(dateAndTime.mode, .dateAndTime)
        XCTAssertEqual(
            timeOnly.accessibilityText,
            "November 1, 2026 at 1:30:12 AM EDT"
        )
        XCTAssertEqual(
            dateAndTime.accessibilityText,
            "October 31, 2026 at 11:59:45 PM EDT"
        )
    }

    func testShelfAndSidePanelHaveParityInBothTimestampModes() throws {
        let context = try TestContext(
            timeZoneIdentifier: "America/New_York",
            now: DateComponents(year: 2026, month: 7, day: 25, hour: 17, minute: 45)
        )
        let today = try context.date(
            DateComponents(year: 2026, month: 7, day: 25, hour: 8, minute: 7)
        )
        let yesterday = try context.date(
            DateComponents(year: 2026, month: 7, day: 24, hour: 23, minute: 59)
        )

        for capturedAt in [today, yesterday] {
            XCTAssertEqual(
                HistoryCardTimestampAdapter.presentation(
                    for: capturedAt,
                    formatter: context.formatter
                ),
                context.formatter.presentation(for: capturedAt)
            )
        }

        for path in [
            "Sources/PasteBuddy/Views/ClipboardShelfPanelView.swift",
            "Sources/PasteBuddy/Views/ClipboardSidePanelView.swift"
        ] {
            let source = try String(
                contentsOfFile: FileManager.default.currentDirectoryPath + "/" + path,
                encoding: .utf8
            )
            XCTAssertTrue(source.contains("HistoryCardTimestampAdapter.presentation"), path)
            XCTAssertFalse(source.contains("ClipboardShelfTimestampAdapter"), path)
            XCTAssertFalse(source.contains("ClipboardSidePanelTimestampAdapter"), path)
        }
    }

    func testTimestampTickerRefreshesOnTheNextMinuteBoundary() throws {
        let context = try TestContext(
            timeZoneIdentifier: "America/New_York",
            now: DateComponents(year: 2026, month: 7, day: 25, hour: 23, minute: 59, second: 30)
        )
        let now = try context.date(
            DateComponents(year: 2026, month: 7, day: 25, hour: 23, minute: 59, second: 30)
        )
        let midnight = try context.date(
            DateComponents(year: 2026, month: 7, day: 26, hour: 0)
        )

        XCTAssertEqual(
            HistoryCardTimestampTicker.nextMinuteBoundary(after: now),
            midnight
        )
    }
}

private struct TestContext {
    let calendar: Calendar
    let formatter: HistoryCardTimestampFormatter

    init(
        timeZoneIdentifier: String,
        localeIdentifier: String = "en_US",
        now components: DateComponents
    ) throws {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = try XCTUnwrap(TimeZone(identifier: timeZoneIdentifier))
        calendar.timeZone = timeZone
        let now = try XCTUnwrap(calendar.date(from: components))
        self.init(
            calendar: calendar,
            locale: Locale(identifier: localeIdentifier),
            timeZone: timeZone,
            now: now
        )
    }

    init(
        timeZoneIdentifier: String,
        localeIdentifier: String = "en_US",
        now: Date
    ) throws {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = try XCTUnwrap(TimeZone(identifier: timeZoneIdentifier))
        calendar.timeZone = timeZone
        self.init(
            calendar: calendar,
            locale: Locale(identifier: localeIdentifier),
            timeZone: timeZone,
            now: now
        )
    }

    private init(calendar: Calendar, locale: Locale, timeZone: TimeZone, now: Date) {
        self.calendar = calendar
        formatter = HistoryCardTimestampFormatter(
            now: { now },
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )
    }

    func date(_ components: DateComponents) throws -> Date {
        try XCTUnwrap(calendar.date(from: components))
    }
}
