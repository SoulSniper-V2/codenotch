import Foundation

/// Untyped JSON access for provider payloads, so sixty fetchers do not each
/// hand-roll the same key-path walk.
///
/// Paths are dot-separated with numeric segments for arrays
/// (`"limits.0.percentUsed"`, `"data.items.3.quota"`). Numbers decode from
/// JSON numbers or numeric strings; dates decode from ISO-8601 (fractional or
/// plain) or epoch seconds/milliseconds (split at 1e12).
enum MiniJSON {
    static func root(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }

    static func value(_ root: Any?, _ path: String) -> Any? {
        var current = root
        for segment in path.split(separator: ".") {
            if let index = Int(segment),
               let array = current as? [Any], array.indices.contains(index) {
                current = array[index]
            } else if let dict = current as? [String: Any] {
                current = dict[String(segment)]
            } else {
                return nil
            }
            if current is NSNull { return nil }
        }
        return current
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        guard let d = double(value), d.isFinite else { return nil }
        return Int(d)
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func bool(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }

    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            guard raw > 0, raw.isFinite else { return nil }
            // Milliseconds past 1e12 (2286 in seconds would be absurd anyway).
            return Date(timeIntervalSince1970: raw > 1e12 ? raw / 1_000 : raw)
        }
        guard let text = (value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        if let date = ISO8601DateFormatter().date(from: text) { return date }

        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        if let date = dateOnly.date(from: text) { return date }

        let custom = DateFormatter()
        custom.calendar = Calendar(identifier: .gregorian)
        custom.locale = Locale(identifier: "en_US_POSIX")
        custom.timeZone = TimeZone(secondsFromGMT: 0)
        custom.dateFormat = "yyyy-MM-dd"
        return custom.date(from: text)
    }

    /// 0-100 clamp for percentages that arrive as 0-1 ratios or overshoot.
    static func percent(_ value: Double?, ratio: Bool = false) -> Double? {
        guard var value else { return nil }
        if ratio { value *= 100 }
        guard value.isFinite else { return nil }
        return min(max(value, 0), 100) / 100
    }

    static func minutesBetween(_ start: Date?, _ end: Date?) -> Double? {
        guard let start, let end, end > start else { return nil }
        let minutes = (end.timeIntervalSince(start) / 60).rounded()
        return minutes > 0 ? minutes : nil
    }
}
