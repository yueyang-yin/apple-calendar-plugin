import Foundation
import EventKit

func makeRecurrence(_ args: [String: Any], start: Date, tz: TimeZone) throws -> EKRecurrenceRule {
    let names = ["daily", "weekly", "monthly", "yearly"]
    guard let index = names.firstIndex(of: args["frequency"] as? String ?? ""),
          let frequency = EKRecurrenceFrequency(rawValue: index) else {
        throw CalendarFailure("invalid_arguments", "Invalid recurrence frequency.")
    }
    try require(args["count"] == nil || args["until"] == nil, "recurrence.count and recurrence.until are mutually exclusive.")
    try require(args["weekdays"] == nil || args["ordinal_weekdays"] == nil,
                "Use weekdays or ordinal_weekdays, not both.")
    let weekdays = args["weekdays"] as? [Int]
    let ordinals = args["ordinal_weekdays"] as? [[String: Any]]
    if weekdays != nil { try require(frequency != .daily, "Daily rules cannot filter weekdays; use a weekly rule.") }
    if ordinals != nil {
        try require(frequency == .monthly || frequency == .yearly, "Ordinal weekdays require monthly or yearly recurrence.")
    }
    let restricted: [(String, EKRecurrenceFrequency)] = [("days_of_month", .monthly), ("months_of_year", .yearly),
        ("weeks_of_year", .yearly), ("days_of_year", .yearly)]
    for (key, required) in restricted where args[key] != nil {
        try require(frequency == required, "\(key) is not supported for this frequency by EventKit.")
    }
    for key in ["days_of_month", "weeks_of_year", "days_of_year", "set_positions"] {
        if let values = args[key] as? [Int] { try require(!values.contains(0), "\(key) cannot contain zero.") }
    }
    try require(!(args["days_of_month"] != nil && ordinals != nil),
                "EventKit cannot combine ordinal weekdays with specific days_of_month; choose one pattern.")
    if args["set_positions"] != nil {
        try require(["weekdays", "ordinal_weekdays", "days_of_month", "months_of_year", "weeks_of_year", "days_of_year"].contains { args[$0] != nil },
                    "set_positions needs at least one recurrence filter.")
    }
    var days = weekdays?.map { EKRecurrenceDayOfWeek(EKWeekday(rawValue: $0)!) }
    if let ordinals = ordinals {
        days = try ordinals.map { entry in
            let number = entry["week_number"] as! Int
            let maximum = frequency == .monthly ? 5 : 53
            try require(number != 0 && abs(number) <= maximum, "Ordinal week_number must be nonzero and within ±\(maximum).")
            return EKRecurrenceDayOfWeek(EKWeekday(rawValue: entry["day"] as! Int)!, weekNumber: number)
        }
    }
    var end: EKRecurrenceEnd?
    if let count = args["count"] as? Int { end = EKRecurrenceEnd(occurrenceCount: count) }
    if let until = args["until"] as? String {
        let date = try parseDate(until, in: tz)
        try require(date >= start, "recurrence.until must not precede the event start.")
        end = EKRecurrenceEnd(end: date)
    }
    func numbers(_ key: String) -> [NSNumber]? { (args[key] as? [Int])?.map { NSNumber(value: $0) } }
    let result = EKRecurrenceRule(recurrenceWith: frequency, interval: args["interval"] as? Int ?? 1,
        daysOfTheWeek: days, daysOfTheMonth: numbers("days_of_month"), monthsOfTheYear: numbers("months_of_year"),
        weeksOfTheYear: numbers("weeks_of_year"), daysOfTheYear: numbers("days_of_year"),
        setPositions: numbers("set_positions"), end: end)
    let retained = recurrenceOutput(result)
    for key in ["days_of_month", "months_of_year", "weeks_of_year", "days_of_year", "set_positions"] {
        if let requested = args[key] as? [Int] {
            let actual = (retained[key] as? [NSNumber] ?? []).map(\.intValue)
            try require(Set(requested) == Set(actual), "EventKit did not retain \(key) for this combination; the event was not saved.")
        }
    }
    return result
}

func recurrenceOutput(_ rule: EKRecurrenceRule) -> [String: Any] {
    var output: [String: Any] = ["frequency": ["daily", "weekly", "monthly", "yearly"][rule.frequency.rawValue],
                               "interval": rule.interval, "first_day_of_week": rule.firstDayOfTheWeek]
    if let days = rule.daysOfTheWeek {
        output["weekdays"] = days.map { ["day": $0.dayOfTheWeek.rawValue, "week_number": $0.weekNumber] }
    }
    if let value = rule.daysOfTheMonth { output["days_of_month"] = value }
    if let value = rule.monthsOfTheYear { output["months_of_year"] = value }
    if let value = rule.weeksOfTheYear { output["weeks_of_year"] = value }
    if let value = rule.daysOfTheYear { output["days_of_year"] = value }
    if let value = rule.setPositions { output["set_positions"] = value }
    if let end = rule.recurrenceEnd {
        if let until = end.endDate { output["until"] = timestamp(until) }
        if end.occurrenceCount > 0 { output["count"] = end.occurrenceCount }
    }
    return output
}
