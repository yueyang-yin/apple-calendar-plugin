import Foundation
import MapKit
import EventKit
import CoreLocation

func mapItem(point: CLLocation, title: String) -> MKMapItem {
    let item: MKMapItem
    if #available(macOS 26.0, *) { item = MKMapItem(location: point, address: nil) }
    else { item = MKMapItem(placemark: MKPlacemark(coordinate: point.coordinate)) }
    item.name = title
    return item
}

func directionsURL(origin: MKMapItem, destination: MKMapItem, mode: String) -> String {
    let from = mapLocation(origin).coordinate
    let to = mapLocation(destination).coordinate
    var url = URLComponents(string: "https://maps.apple.com/")!
    url.queryItems = [URLQueryItem(name: "saddr", value: "\(from.latitude),\(from.longitude)"),
        URLQueryItem(name: "daddr", value: "\(to.latitude),\(to.longitude)"),
        URLQueryItem(name: "dirflg", value: ["walking": "w", "driving": "d", "transit": "r", "cycling": "c"][mode]!)]
    return url.url!.absoluteString
}

func transport(_ mode: String) -> MKDirectionsTransportType {
    switch mode { case "walking": return .walking; case "driving": return .automobile
    case "transit": return .transit; default: return .cycling }
}

func routeEstimate(origin: MKMapItem, destination: MKMapItem, mode: String,
                   departure: Date?, arrival: Date?, tz: TimeZone = .current) throws -> [String: Any] {
    try require(departure == nil || arrival == nil, "Provide depart_at or arrive_by, not both.")
    if mapLocation(origin).distance(from: mapLocation(destination)) < 0.01 {
        let date = arrival ?? departure ?? Date()
        return ["provider": "identical map coordinates", "transport_type": mode, "travel_seconds": 0,
                "travel_minutes": 0, "distance_meters": 0, "estimated_departure": timestamp(date, in: tz),
                "estimated_arrival": timestamp(date, in: tz), "calculated_at": timestamp(Date()),
                "apple_maps_url": directionsURL(origin: origin, destination: destination, mode: mode),
                "estimate_note": "The endpoints have identical map coordinates. Allow an explicit buffer for movement inside a building, different floors or entrances."]
    }
    let semaphore = DispatchSemaphore(value: 0)
    var outcome: Result<MKDirections.ETAResponse, Error>?
    var operation: MKDirections?
    DispatchQueue.main.async {
        let request = MKDirections.Request()
        request.source = origin
        request.destination = destination
        request.transportType = transport(mode)
        request.departureDate = departure
        request.arrivalDate = arrival
        let directions = MKDirections(request: request)
        operation = directions
        directions.calculateETA { response, error in
            if let error = error { outcome = .failure(error) }
            else if let response = response { outcome = .success(response) }
            else { outcome = .failure(CalendarFailure("route_unavailable", "No route estimate was returned.")) }
            semaphore.signal()
        }
    }
    guard semaphore.wait(timeout: .now() + 20) == .success else {
        DispatchQueue.main.async { operation?.cancel() }
        throw CalendarFailure("route_timeout", "Apple Maps route estimation timed out. No calendar data was changed.")
    }
    let response: MKDirections.ETAResponse
    do { response = try outcome!.get() }
    catch { throw CalendarFailure("route_unavailable", "Apple Maps could not estimate this route for \(mode): \(error.localizedDescription). No straight-line travel-time substitute was used.") }
    try require(response.expectedTravelTime.isFinite && response.expectedTravelTime >= 0, "Invalid route duration returned by Apple Maps.")
    guard response.transportType == transport(mode) else {
        throw CalendarFailure("route_mode_unavailable", "Apple Maps returned a different transport mode; the requested route was not verified.")
    }
    return ["provider": "Apple Maps / MapKit", "transport_type": mode,
            "travel_seconds": ceil(response.expectedTravelTime), "travel_minutes": ceil(response.expectedTravelTime / 60),
            "distance_meters": response.distance.rounded(), "estimated_departure": timestamp(response.expectedDepartureDate, in: tz),
            "estimated_arrival": timestamp(response.expectedArrivalDate, in: tz), "calculated_at": timestamp(Date()),
            "apple_maps_url": directionsURL(origin: origin, destination: destination, mode: mode),
            "estimate_note": "An estimate from Apple Maps, not a guaranteed arrival or a live departure alert. Availability depends on region, transport mode and requested date."]
}

func journeyTiming(availableFrom: Date, arriveBy: Date, travelSeconds: Double, bufferMinutes: Int, tz: TimeZone = .current) -> [String: Any] {
    let required = travelSeconds + Double(bufferMinutes * 60)
    let available = arriveBy.timeIntervalSince(availableFrom)
    return ["available_minutes": available / 60, "required_minutes": required / 60,
            "buffer_minutes": bufferMinutes, "latest_departure": timestamp(arriveBy.addingTimeInterval(-required), in: tz),
            "can_arrive_on_time": available >= required,
            "shortfall_minutes": max(0, ceil((required - available) / 60))]
}

extension CalendarService {
    func endpoint(_ args: [String: Any]) throws -> (MKMapItem, EKEvent?) {
        try require(["place_ref", "event_ref", "coordinates"].filter { args[$0] != nil }.count == 1,
                    "Each route endpoint needs exactly one of place_ref, event_ref or coordinates.")
        if let ref = args["place_ref"] as? String { return (try places.mapItem(ref), nil) }
        if let data = args["coordinates"] as? [String: Any] {
            return (mapItem(point: try coordinates(data), title: data["title"] as? String ?? "Map location"), nil)
        }
        try access()
        let event = try resolve(args["event_ref"] as! String)
        guard let native = event.structuredLocation, let point = native.geoLocation else {
            throw CalendarFailure("location_coordinates_required", "This event has no native geographic location. Resolve its destination with search_places before calculating a route; a text label is not sufficient.")
        }
        return (mapItem(point: point, title: native.title ?? event.location ?? "Event location"), event)
    }

    func calculateRoute(_ args: [String: Any]) throws -> [String: Any] {
        try require(args["depart_at"] == nil || args["arrive_by"] == nil, "Provide depart_at or arrive_by, not both.")
        let tz = try zone(args)
        let departure = try (args["depart_at"] as? String).map { try parseDate($0, in: tz) }
        let arrival = try (args["arrive_by"] as? String).map { try parseDate($0, in: tz) }
        let (origin, _) = try endpoint(args["origin"] as! [String: Any])
        let (destination, _) = try endpoint(args["destination"] as! [String: Any])
        return try routeEstimate(origin: origin, destination: destination,
                                 mode: args["transport_type"] as? String ?? "walking", departure: departure, arrival: arrival, tz: tz)
    }

    func travelFeasibility(_ args: [String: Any]) throws -> [String: Any] {
        let (origin, previous) = try endpoint(args["origin"] as! [String: Any])
        let (destination, next) = try endpoint(args["destination"] as! [String: Any])
        let tz = try zone(args)
        let from = try (args["available_from"] as? String).map { try parseDate($0, in: tz) }
            ?? (previous?.isAllDay == false ? previous?.endDate : nil)
        let until = try (args["arrive_by"] as? String).map { try parseDate($0, in: tz) }
            ?? (next?.isAllDay == false ? next?.startDate : nil)
        guard let availableFrom = from, let arriveBy = until else {
            throw CalendarFailure("invalid_arguments", "Provide available_from and arrive_by for planned locations or all-day events. Timed event endpoints can supply their end/start boundaries automatically.")
        }
        try require(abs(arriveBy.timeIntervalSince(availableFrom)) <= 31 * 86400, "Journey checks are limited to a 31-day interval.")
        let buffer = args["buffer_minutes"] as? Int ?? 0
        let route = try routeEstimate(origin: origin, destination: destination,
            mode: args["transport_type"] as? String ?? "walking", departure: nil,
            arrival: arriveBy.addingTimeInterval(Double(-buffer * 60)), tz: tz)
        let travel = (route["travel_seconds"] as! NSNumber).doubleValue
        var timing = journeyTiming(availableFrom: availableFrom, arriveBy: arriveBy, travelSeconds: travel, bufferMinutes: buffer, tz: tz)
        let leave = arriveBy.addingTimeInterval(-travel - Double(buffer * 60))
        // Include existing appointments in the reserved journey interval; never move them automatically.
        let queryStart = min(leave, arriveBy.addingTimeInterval(-1))
        var query: [String: Any] = ["start": timestamp(queryStart), "end": timestamp(arriveBy)]
        if let ids = args["calendar_ids"] { query["calendar_ids"] = ids }
        let excluded = Set([previous, next].compactMap { $0 }.map { reference($0) })
        let conflicts = try events(query).filter { isBusy($0) && !excluded.contains(reference($0)) }
        timing["feasible"] = timing["can_arrive_on_time"] as! Bool && conflicts.isEmpty
        timing["conflicts"] = conflicts.map { serialize($0, details: false) }
        timing["available_from"] = timestamp(availableFrom, in: tz)
        timing["arrive_by"] = timestamp(arriveBy, in: tz)
        timing["route"] = route
        timing["calendar_changes"] = 0
        timing["coverage_note"] = "Checks synced calendars only. Includes the explicit arrival buffer. It does not reserve travel time or enable Apple's dynamic Time to Leave alerts."
        return timing
    }

    func isBusy(_ event: EKEvent) -> Bool {
        event.status != .canceled && event.availability != .free &&
        !(event.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }
    }
}
