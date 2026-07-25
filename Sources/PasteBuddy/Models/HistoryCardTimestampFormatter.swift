import Foundation

struct HistoryCardTimestampFormatter {
    struct Presentation: Equatable {
        enum Mode: Equatable {
            case timeOnly
            case dateAndTime
        }

        let mode: Mode
        let visibleText: String
        let accessibilityText: String
    }

    private let now: () -> Date
    private let calendar: Calendar
    private let timeOnlyStyle: Date.FormatStyle
    private let sameYearStyle: Date.FormatStyle
    private let olderYearStyle: Date.FormatStyle
    private let accessibilityStyle: Date.FormatStyle

    init(
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        var calendar = calendar
        calendar.timeZone = timeZone
        let style = Date.FormatStyle(
            locale: locale,
            calendar: calendar,
            timeZone: timeZone
        )

        self.now = now
        self.calendar = calendar
        timeOnlyStyle = style.hour().minute()
        sameYearStyle = style.month(.abbreviated).day().hour().minute()
        olderYearStyle = style.year().month(.abbreviated).day().hour().minute()
        accessibilityStyle = style
            .year()
            .month(.wide)
            .day()
            .hour()
            .minute()
            .second()
            .timeZone(.specificName(.short))
    }

    func presentation(for capturedAt: Date) -> Presentation {
        let currentDate = now()
        let isToday = calendar.isDate(capturedAt, inSameDayAs: currentDate)
        let visibleStyle = if isToday {
            timeOnlyStyle
        } else if calendar.component(.year, from: capturedAt)
            == calendar.component(.year, from: currentDate) {
            sameYearStyle
        } else {
            olderYearStyle
        }

        return Presentation(
            mode: isToday ? .timeOnly : .dateAndTime,
            visibleText: capturedAt.formatted(visibleStyle),
            accessibilityText: capturedAt.formatted(accessibilityStyle)
        )
    }
}

enum HistoryCardTimestampAdapter {
    static func presentation(
        for capturedAt: Date,
        formatter: HistoryCardTimestampFormatter
    ) -> HistoryCardTimestampFormatter.Presentation {
        formatter.presentation(for: capturedAt)
    }
}

enum HistoryCardTimestampTicker {
    static func nextMinuteBoundary(after date: Date) -> Date {
        let elapsedMinutes = floor(date.timeIntervalSinceReferenceDate / 60)
        return Date(timeIntervalSinceReferenceDate: (elapsedMinutes + 1) * 60)
    }

    @MainActor
    static func run(update: @escaping (Date) -> Void) async {
        while !Task.isCancelled {
            let currentDate = Date()
            let nextMinute = nextMinuteBoundary(after: currentDate)
            do {
                try await Task.sleep(for: .seconds(nextMinute.timeIntervalSince(currentDate)))
            } catch {
                return
            }
            update(Date())
        }
    }
}
