import Foundation

enum ClipboardItemTimestampFormatter {
    static func string(
        for date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        var style = Date.FormatStyle.dateTime
            .year()
            .month(.abbreviated)
            .day()
            .hour()
            .minute()
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
    }
}
