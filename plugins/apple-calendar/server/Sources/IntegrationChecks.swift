import Foundation
import EventKit

// Explicit diagnostics only: create an isolated fixture calendar, then remove that exact calendar.
func integrationChecks(inspectUI: Bool) throws -> [String: Any] {
    let service = CalendarService()
    try service.access()
    guard let source = service.store.defaultCalendarForNewEvents?.source else {
        throw CalendarFailure("verification_unavailable", "No default event source is available for an isolated verification calendar.")
    }
    let fixture = EKCalendar(for: .event, eventStore: service.store)
    let title = "Apple Calendar Verification " + UUID().uuidString
    fixture.title = title
    fixture.source = source
    try service.store.saveCalendar(fixture, commit: true)
    let calendarID = fixture.calendarIdentifier
    var count = 0
    var handoffs: [String: Any] = [:]
    func check(_ condition: Bool, _ message: String) throws {
        try require(condition, "Integration verification: \(message)"); count += 1
    }
    func clean() throws {
        service.store.reset()
        guard let owned = service.store.calendar(withIdentifier: calendarID) else { return }
        try require(owned.title == title, "The fixture calendar identity changed; cleanup stopped.")
        try service.store.removeCalendar(owned, commit: true)
        service.store.reset()
        try require(service.store.calendar(withIdentifier: calendarID) == nil, "Fixture calendar cleanup did not persist.")
    }
    func create(_ fields: [String: Any]) throws -> [String: Any] {
        let saved = try service.call("create_event", fields.merging(["calendar_id": calendarID, "reminder_minutes": []]) { _, new in new })
        try check((saved["persistence"] as? [String: Any])?["read_back_verified"] as? Bool == true, "Saved event survives database reset")
        return saved["event"] as! [String: Any]
    }
    func listing(_ start: String, _ end: String) throws -> [[String: Any]] {
        try service.call("list_events", ["calendar_ids": [calendarID], "start": start, "end": end, "limit": 200])["events"] as! [[String: Any]]
    }
    do {
        let search = try service.call("search_places", ["query": "Guildford Railway Station, Guildford, United Kingdom", "limit": 1])
        guard let selected = (search["places"] as? [[String: Any]])?.first else {
            throw CalendarFailure("verification_unavailable", "The public test destination was not found in Apple Maps.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        let start = calendar.date(bySettingHour: 13, minute: 0, second: 0, of: tomorrow)!
        let destination = try create(["title": "Native map location verification", "start": timestamp(start),
            "end": timestamp(start.addingTimeInterval(3600)), "place_ref": selected["place_ref"]!])
        let ref = destination["event_ref"] as! String
        let original = destination["structured_location"] as? [String: Any]
        try check(original?["has_coordinates"] as? Bool == true, "Native POI coordinates survive a real save")
        let updated = try service.call("update_event", ["event_ref": ref, "notes": "Verification fixture; no alerts or attendees."])
        try check((updated["persistence"] as? [String: Any])?["native_location_verified"] as? Bool == true,
                  "Unrelated persisted edit preserves native coordinates")
        let point: [String: Any] = ["title": "Verified coordinate pin", "latitude": selected["latitude"]!, "longitude": selected["longitude"]!]
        let pin = try create(["title": "Coordinate pin verification", "start": timestamp(start.addingTimeInterval(7200)),
            "end": timestamp(start.addingTimeInterval(10800)), "structured_location": point])
        try check((pin["structured_location"] as? [String: Any])?["has_coordinates"] as? Bool == true,
                  "Generic coordinate pins survive a real save")
        if CommandLine.arguments.contains("--handoff-only") {
            handoffs["calendar"] = try service.call("open_event", ["event_ref": ref])
            if inspectUI {
                print(jsonString(["inspection": "calendar", "fixture_calendar_id": calendarID])); fflush(stdout); _ = readLine()
            }
            handoffs["maps"] = try service.call("open_in_maps", ["destination": ["event_ref": ref]])
            if inspectUI {
                print(jsonString(["inspection": "maps", "fixture_calendar_id": calendarID])); fflush(stdout); _ = readLine()
            }
            try clean()
            return ["integration_checks_passed": count, "fixture_calendar_removed": true, "handoffs": handoffs]
        }

        _ = try create(["title": "Second weekday verification", "start": "2031-01-14T13:00:00Z", "end": "2031-01-14T14:00:00Z",
            "time_zone": "Europe/London", "recurrence": ["frequency": "monthly", "ordinal_weekdays": [["day": 3, "week_number": 2]], "count": 3]])
        var expanded = try listing("2031-01-01T00:00:00Z", "2031-04-01T00:00:00Z")
        try check(expanded.map { String(($0["start"] as! String).prefix(10)) } == ["2031-01-14", "2031-02-11", "2031-03-11"],
                  "EventKit expands the second Tuesday of each month")
        _ = try service.call("update_event", ["event_ref": expanded[1]["event_ref"]!, "scope": "entire_series", "title": "Entire series verified"])
        expanded = try listing("2031-01-01T00:00:00Z", "2031-04-01T00:00:00Z")
        try check(expanded.count == 3 && expanded.allSatisfy { $0["title"] as? String == "Entire series verified" },
                  "Entire-series edit from a later occurrence updates the first occurrence too")
        _ = try service.call("delete_event", ["event_ref": expanded[2]["event_ref"]!, "scope": "entire_series"])
        try check(try listing("2031-01-01T00:00:00Z", "2031-04-01T00:00:00Z").isEmpty, "Entire-series deletion removes earlier occurrences")

        _ = try create(["title": "Last weekday verification", "start": "2031-01-31T13:00:00Z", "end": "2031-01-31T14:00:00Z",
            "time_zone": "Europe/London", "recurrence": ["frequency": "monthly", "weekdays": [2, 3, 4, 5, 6], "set_positions": [-1], "count": 3]])
        expanded = try listing("2031-01-01T00:00:00Z", "2031-04-01T00:00:00Z")
        try check(expanded.map { String(($0["start"] as! String).prefix(10)) } == ["2031-01-31", "2031-02-28", "2031-03-31"],
                  "EventKit expands the last calendar weekday, including variable month length")
        _ = try service.call("delete_event", ["event_ref": expanded[0]["event_ref"]!, "scope": "entire_series"])
        _ = try create(["title": "Yearly month verification", "start": "2031-02-15T13:00:00Z", "end": "2031-02-15T14:00:00Z",
            "time_zone": "Europe/London", "recurrence": ["frequency": "yearly", "months_of_year": [2, 8], "count": 4]])
        expanded = try listing("2031-01-01T00:00:00Z", "2031-12-31T23:59:59Z")
        try check(expanded.map { String(($0["start"] as! String).prefix(10)) } == ["2031-02-15", "2031-08-15"], "Yearly month filters expand natively")
        _ = try service.call("delete_event", ["event_ref": expanded[0]["event_ref"]!, "scope": "entire_series"])

        _ = try create(["title": "DST recurrence verification", "start": "2031-03-23T10:00:00Z", "end": "2031-03-23T11:00:00Z",
            "time_zone": "Europe/London", "recurrence": ["frequency": "weekly", "count": 3]])
        expanded = try listing("2031-03-22T00:00:00Z", "2031-04-10T00:00:00Z")
        try check(expanded.count == 3 && expanded.allSatisfy { ($0["start"] as! String).contains("T10:00:00") },
                  "Repeated local time survives the daylight-saving transition")
        try check((expanded.last?["start"] as? String)?.hasSuffix("+01:00") == true, "DST recurrence uses the target date offset")

        let origin = try create(["title": "Journey origin verification", "start": timestamp(start.addingTimeInterval(-7200)),
            "end": timestamp(start.addingTimeInterval(-3600)),
            "structured_location": ["title": "Public route origin", "latitude": 51.2351, "longitude": -0.5748]])
        let journey: [String: Any] = ["origin": ["event_ref": origin["event_ref"]!], "destination": ["event_ref": ref],
            "transport_type": "walking", "buffer_minutes": 5, "calendar_ids": [calendarID]]
        let feasible = try service.call("check_travel_feasibility", journey)
        try check(feasible["feasible"] as? Bool == true, "Real MapKit route fits the gap between two events")
        let route = feasible["route"] as! [String: Any]
        try check((route["travel_seconds"] as! NSNumber).doubleValue > 0 && (route["distance_meters"] as! NSNumber).doubleValue > 0,
                  "Route returns real distance and ETA")
        _ = try create(["title": "Journey conflict verification", "start": timestamp(start.addingTimeInterval(-60)),
            "end": timestamp(start.addingTimeInterval(-30))])
        let blocked = try service.call("check_travel_feasibility", journey)
        try check(blocked["feasible"] as? Bool == false && (blocked["conflicts"] as? [[String: Any]])?.count == 1,
                  "Existing calendar appointment blocks the travel interval")

        handoffs["calendar"] = try service.call("open_event", ["event_ref": ref])
        if inspectUI {
            print(jsonString(["inspection": "calendar", "fixture_calendar_id": calendarID, "fixture_event_ref": ref, "title": destination["title"]!]))
            fflush(stdout)
            _ = readLine()
        }
        handoffs["maps"] = try service.call("open_in_maps", ["origin": ["event_ref": origin["event_ref"]!],
            "destination": ["event_ref": ref], "transport_type": "walking"])
        if inspectUI {
            print(jsonString(["inspection": "maps", "fixture_calendar_id": calendarID]))
            fflush(stdout)
            _ = readLine()
        }
        try clean()
        return ["integration_checks_passed": count, "fixture_calendar_removed": true, "handoffs": handoffs,
                "existing_appointments_changed": 0, "remote_sync_verified": false]
    } catch {
        do { try clean() }
        catch { throw CalendarFailure("fixture_cleanup_failed", "Remove only the verification calendar \(calendarID), titled \(title). Cleanup failed: \(error)") }
        throw error
    }
}
