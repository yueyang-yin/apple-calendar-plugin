import Foundation
import EventKit
import CoreLocation

func checkPlaces(query: String, nearAddress: String?) throws -> [String: Any] {
    let service = CalendarService()
    var args: [String: Any] = ["query": query, "limit": 5]
    if let nearAddress = nearAddress { args["near_address"] = nearAddress }
    let search = try service.call("search_places", args)
    guard let candidates = search["places"] as? [[String: Any]], let selected = candidates.first,
          let reference = selected["place_ref"] as? String else {
        return ["query": query, "matches": [], "native_location_check": "no_results", "live_calendar_writes": 0]
    }
    let store = EKEventStore()
    let event = EKEvent(eventStore: store)
    event.calendar = EKCalendar(for: .event, eventStore: store)
    event.title = "Unsaved native-location verification"
    event.startDate = Date().addingTimeInterval(86400)
    event.endDate = event.startDate.addingTimeInterval(3600)
    try service.edit(event, ["place_ref": reference], creating: false)
    guard let native = event.structuredLocation, let savedPoint = native.geoLocation else {
        throw CalendarFailure("verification_failed", "The selected map item did not produce a native geographic location.")
    }
    let expected = try coordinates(selected)
    try require(savedPoint.distance(from: expected) < 2, "Native event coordinates do not match the selected map result.")
    try service.edit(event, ["title": "Preserve the native place"], creating: false)
    try require(event.structuredLocation?.geoLocation != nil, "An unrelated edit discarded the native place.")
    var summary = selected
    summary.removeValue(forKey: "place_ref")
    return ["query": query, "matches": candidates.map { candidate -> [String: Any] in
        var output: [String: Any] = ["name": candidate["name"] ?? "", "address": candidate["address"] ?? ""]
        if let distance = candidate["distance_meters"] { output["distance_meters"] = distance }
        return output
    }, "selected": summary, "native_location": structuredLocationOutput(native),
            "native_location_check": "passed", "live_calendar_writes": 0]
}
