import Foundation
import EventKit
import CoreLocation

func advancedSelfTest() throws -> Int {
    var count = 0
    func check(_ condition: Bool, _ message: String) throws {
        try require(condition, "Advanced self-test: \(message)"); count += 1
    }
    let tz = TimeZone(identifier: "Europe/London")!
    let start = try parseDate("2031-01-14T13:00:00Z", in: tz)
    func rule(_ args: [String: Any]) throws -> EKRecurrenceRule {
        try validate(args, schema: recurrenceField)
        return try makeRecurrence(args, start: start, tz: tz)
    }
    func reject(_ args: [String: Any]) throws {
        do { _ = try rule(args) } catch { count += 1; return }
        throw CalendarFailure("self_test_failed", "Accepted an invalid recurrence: \(jsonString(args))")
    }
    let second = try rule(["frequency": "monthly", "ordinal_weekdays": [["day": 3, "week_number": 2]], "count": 4])
    try check(second.daysOfTheWeek?.first?.weekNumber == 2 && second.daysOfTheWeek?.first?.dayOfTheWeek == .tuesday,
              "Second weekday uses the native ordinal")
    let last = try rule(["frequency": "monthly", "weekdays": [2, 3, 4, 5, 6], "set_positions": [-1]])
    try check(last.setPositions?.first?.intValue == -1 && last.daysOfTheWeek?.count == 5, "Last weekday filter")
    let dates = try rule(["frequency": "monthly", "days_of_month": [1, 15, -1]])
    try check(dates.daysOfTheMonth?.map(\.intValue) == [1, 15, -1], "Multiple month dates and negative month day")
    let yearly = try rule(["frequency": "yearly", "months_of_year": [2, 8], "weekdays": [2], "set_positions": [1]])
    try check(yearly.monthsOfTheYear?.map(\.intValue) == [2, 8], "Yearly month filter")
    let yearDays = try rule(["frequency": "yearly", "days_of_year": [1, -1]])
    try check(yearDays.daysOfTheYear?.count == 2, "Yearly day filter")
    let yearWeeks = try rule(["frequency": "yearly", "weeks_of_year": [1, -1], "weekdays": [2]])
    try check(yearWeeks.weeksOfTheYear?.count == 2, "Yearly week filter")
    let output = recurrenceOutput(yearWeeks)
    try check(output["weeks_of_year"] != nil && output["first_day_of_week"] != nil, "Serialize complete native recurrence")
    for args: [String: Any] in [
        ["frequency": "daily", "weekdays": [2]],
        ["frequency": "weekly", "ordinal_weekdays": [["day": 3, "week_number": 2]]],
        ["frequency": "monthly", "ordinal_weekdays": [["day": 3, "week_number": 0]]],
        ["frequency": "monthly", "ordinal_weekdays": [["day": 3, "week_number": 6]]],
        ["frequency": "monthly", "ordinal_weekdays": [["day": 3, "week_number": 2]], "days_of_month": [14]],
        ["frequency": "monthly", "weekdays": [3], "ordinal_weekdays": [["day": 3, "week_number": 2]]],
        ["frequency": "monthly", "days_of_month": [0]],
        ["frequency": "weekly", "days_of_month": [1]],
        ["frequency": "monthly", "months_of_year": [2]],
        ["frequency": "yearly", "weeks_of_year": [0]],
        ["frequency": "yearly", "days_of_year": [367]],
        ["frequency": "monthly", "set_positions": [-1]],
        ["frequency": "monthly", "weekdays": [2, 2]],
        ["frequency": "monthly", "weekdays": [2], "set_positions": [0]]
    ] { try reject(args) }
    let arrival = start.addingTimeInterval(3600)
    let exact = journeyTiming(availableFrom: start, arriveBy: arrival, travelSeconds: 3000, bufferMinutes: 10)
    try check(exact["can_arrive_on_time"] as? Bool == true && exact["shortfall_minutes"] as? Double == 0, "Exact journey fit includes arrival buffer")
    let short = journeyTiming(availableFrom: start, arriveBy: arrival, travelSeconds: 3001, bufferMinutes: 10)
    try check(short["can_arrive_on_time"] as? Bool == false && short["shortfall_minutes"] as? Double == 1, "Insufficient journey time rounds shortfall up")
    let overlap = journeyTiming(availableFrom: arrival, arriveBy: start, travelSeconds: 100, bufferMinutes: 0)
    try check(overlap["can_arrive_on_time"] as? Bool == false, "Overlapping appointments cannot be a feasible journey")
    let origin = mapItem(point: CLLocation(latitude: 51.24, longitude: -0.59), title: "A & B")
    let destination = mapItem(point: CLLocation(latitude: 51.23, longitude: -0.58), title: "Another destination")
    let url = directionsURL(origin: origin, destination: destination, mode: "walking")
    try check(url.contains("saddr=") && url.contains("daddr=") && url.contains("dirflg=w"), "Native Maps directions preserve both endpoints and mode")
    let same = try routeEstimate(origin: origin, destination: origin, mode: "walking", departure: start, arrival: nil, tz: tz)
    try check(same["travel_seconds"] as? Int == 0 && same["provider"] as? String == "identical map coordinates", "Same-building endpoints use zero external travel without fabricating a route")
    let service = CalendarService()
    do { _ = try service.endpoint([:]); throw CalendarFailure("self_test_failed", "Empty endpoint accepted") }
    catch let error as CalendarFailure { try check(error.code == "invalid_arguments", "Reject empty endpoint") }
    do { _ = try service.endpoint(["place_ref": "bad", "coordinates": ["latitude": 0, "longitude": 0]]); throw CalendarFailure("self_test_failed", "Conflicting endpoint accepted") }
    catch let error as CalendarFailure { try check(error.code == "invalid_arguments", "Reject conflicting endpoint") }
    return count
}
