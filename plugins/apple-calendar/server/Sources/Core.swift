import Foundation
import CoreFoundation

let pluginVersion = "1.2.0"

struct CalendarFailure: Error {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CalendarFailure("invalid_arguments", message) }
}

func jsonString(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]),
          let string = String(data: data, encoding: .utf8) else { return "null" }
    return string
}

func zone(_ args: [String: Any]) throws -> TimeZone {
    guard let name = args["time_zone"] as? String else { return .current }
    guard let result = TimeZone(identifier: name) else {
        throw CalendarFailure("invalid_arguments", "Unknown IANA time zone: \(name)")
    }
    return result
}

func dayString(_ date: Date, in tz: TimeZone) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.timeZone = tz
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
}

func timestamp(_ date: Date, in tz: TimeZone = .current) -> String {
    let f = ISO8601DateFormatter()
    f.timeZone = tz
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

func parseDate(_ string: String, in tz: TimeZone, allDay: Bool = false) throws -> Date {
    if allDay {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        if string.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
           let date = f.date(from: string), f.string(from: date) == string { return date }
        throw CalendarFailure("invalid_arguments", "All-day dates must be valid YYYY-MM-DD values.")
    }
    try require(string.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#,
                             options: .regularExpression) != nil,
                "Timed dates require ISO 8601 with seconds and an explicit UTC offset, for example 2026-10-23T09:00:00+01:00.")
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var parsed = f.date(from: string)
    f.formatOptions = [.withInternetDateTime]
    if parsed == nil { parsed = f.date(from: string) }
    if let date = parsed {
        let offset: Int
        if string.hasSuffix("Z") { offset = 0 }
        else {
            let suffix = String(string.suffix(6))
            let hours = Int(suffix.dropFirst().prefix(2)) ?? 99
            let minutes = Int(suffix.suffix(2)) ?? 99
            try require(hours <= 23 && minutes <= 59, "Invalid UTC offset.")
            offset = (hours * 3600 + minutes * 60) * (suffix.hasPrefix("-") ? -1 : 1)
        }
        let check = DateFormatter()
        check.locale = Locale(identifier: "en_US_POSIX")
        check.calendar = Calendar(identifier: .gregorian)
        check.timeZone = TimeZone(secondsFromGMT: offset)
        check.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        try require(check.string(from: date) == String(string.prefix(19)), "Invalid date or time components.")
        return date
    }
    throw CalendarFailure("invalid_arguments", "Invalid ISO 8601 timestamp: \(string)")
}

func range(_ args: [String: Any]) throws -> (Date, Date, TimeZone) {
    let tz = try zone(args)
    guard let startString = args["start"] as? String, let endString = args["end"] as? String else {
        throw CalendarFailure("invalid_arguments", "start and end are required.")
    }
    let start = try parseDate(startString, in: tz)
    let end = try parseDate(endString, in: tz)
    try require(end > start, "end must be later than start (exclusive end).")
    try require(end.timeIntervalSince(start) <= 366 * 86400, "Search windows must not exceed 366 days. Split longer searches.")
    return (start, end, tz)
}

func isNumber(_ value: Any) -> Bool {
    guard let n = value as? NSNumber else { return false }
    return CFGetTypeID(n) != CFBooleanGetTypeID()
}

func validate(_ value: Any, schema: [String: Any], path: String = "arguments") throws {
    let type = schema["type"] as? String ?? ""
    switch type {
    case "object":
        guard let object = value as? [String: Any] else { throw CalendarFailure("invalid_arguments", "\(path) must be an object.") }
        let props = schema["properties"] as? [String: [String: Any]] ?? [:]
        for key in schema["required"] as? [String] ?? [] {
            try require(object[key] != nil, "\(path).\(key) is required.")
        }
        for (key, item) in object {
            guard let child = props[key] else { throw CalendarFailure("invalid_arguments", "Unknown field: \(path).\(key)") }
            try validate(item, schema: child, path: "\(path).\(key)")
        }
    case "string":
        guard let string = value as? String else { throw CalendarFailure("invalid_arguments", "\(path) must be a string.") }
        if let min = schema["minLength"] as? Int { try require(string.trimmingCharacters(in: .whitespacesAndNewlines).count >= min, "\(path) is empty.") }
        if let values = schema["enum"] as? [String] { try require(values.contains(string), "\(path) must be one of \(values.joined(separator: ", ")).") }
    case "integer", "number":
        try require(isNumber(value), "\(path) must be a number.")
        let n = (value as! NSNumber).doubleValue
        try require(n.isFinite && (type != "integer" || n.rounded() == n), "\(path) must be an integer.")
        if let min = schema["minimum"] as? NSNumber { try require(n >= min.doubleValue, "\(path) is below its minimum.") }
        if let max = schema["maximum"] as? NSNumber { try require(n <= max.doubleValue, "\(path) exceeds its maximum.") }
    case "boolean":
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw CalendarFailure("invalid_arguments", "\(path) must be a boolean.")
        }
    case "array":
        guard let items = value as? [Any] else { throw CalendarFailure("invalid_arguments", "\(path) must be an array.") }
        if let min = schema["minItems"] as? Int { try require(items.count >= min, "\(path) needs at least \(min) items.") }
        if let max = schema["maxItems"] as? Int { try require(items.count <= max, "\(path) allows at most \(max) items.") }
        if schema["uniqueItems"] as? Bool == true { try require(Set(items.map { jsonString($0) }).count == items.count, "\(path) must contain unique items.") }
        if let child = schema["items"] as? [String: Any] {
            for (index, item) in items.enumerated() { try validate(item, schema: child, path: "\(path)[\(index)]") }
        }
    default: throw CalendarFailure("internal_error", "Invalid tool schema type.")
    }
}

func mergeIntervals(_ intervals: [(Date, Date)], start: Date, end: Date) -> [(Date, Date)] {
    let sorted = intervals.map { (max(start, $0.0), min(end, $0.1)) }.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
    var merged: [(Date, Date)] = []
    for interval in sorted {
        if let previous = merged.last, interval.0 <= previous.1 {
            merged[merged.count - 1] = (previous.0, max(previous.1, interval.1))
        } else { merged.append(interval) }
    }
    return merged
}

func freeIntervals(_ busy: [(Date, Date)], start: Date, end: Date, minimum: Double) -> [(Date, Date)] {
    var result: [(Date, Date)] = []
    var cursor = start
    for item in mergeIntervals(busy, start: start, end: end) {
        if item.0.timeIntervalSince(cursor) >= minimum { result.append((cursor, item.0)) }
        cursor = max(cursor, item.1)
    }
    if end.timeIntervalSince(cursor) >= minimum { result.append((cursor, end)) }
    return result
}
