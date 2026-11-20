import Foundation

/// The short time on a sidebar row: "now", "2m", "3h", "Yesterday", "Sun", "10 Nov", "14 Oct 2025".
/// Both apps use it so a chat reads the same on the Mac and the phone.
public enum SidebarTime {
    public static func relative(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let seconds = now.timeIntervalSince(date)
        // A clock slightly ahead of ours still means "just now".
        if seconds < 60 {
            return "now"
        }
        if seconds < 3_600 {
            return "\(Int(seconds / 60))m"
        }
        if calendar.isDate(date, inSameDayAs: now) {
            return "\(Int(seconds / 3_600))h"
        }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days == 1 {
            return "Yesterday"
        }
        if days < 7 {
            return format(date, "EEE", calendar: calendar, locale: locale)
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return format(date, sameYear ? "d MMM" : "d MMM yyyy", calendar: calendar, locale: locale)
    }

    private static func format(_ date: Date, _ pattern: String, calendar: Calendar, locale: Locale) -> String {
        formatter(pattern, calendar: calendar, locale: locale).string(from: date)
    }

    /// Every row asks on every render, and a DateFormatter is slow to make, so one is kept per
    /// pattern, calendar, time zone and locale.
    private static let cache = FormatterCache()

    private static func formatter(_ pattern: String, calendar: Calendar, locale: Locale) -> DateFormatter {
        let key = "\(pattern)|\(calendar.identifier)|\(calendar.timeZone.identifier)|\(locale.identifier)"
        return cache.formatter(for: key) {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate(pattern)
            return formatter
        }
    }
}

/// Formatters by key, safe to use from any thread.
private final class FormatterCache: @unchecked Sendable {
    private var formatters: [String: DateFormatter] = [:]
    private let lock = NSLock()

    func formatter(for key: String, make: () -> DateFormatter) -> DateFormatter {
        lock.lock()
        defer { lock.unlock() }
        if let formatter = formatters[key] {
            return formatter
        }
        let formatter = make()
        formatters[key] = formatter
        return formatter
    }
}
