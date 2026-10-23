import Foundation
import MapKit
import CoreLocation
import EventKit

func coordinates(_ args: [String: Any]) throws -> CLLocation {
    guard let latitude = args["latitude"] as? NSNumber, isNumber(latitude),
          let longitude = args["longitude"] as? NSNumber, isNumber(longitude) else {
        throw CalendarFailure("invalid_arguments", "latitude and longitude must be numbers.")
    }
    let lat = latitude.doubleValue
    let lon = longitude.doubleValue
    try require(lat.isFinite && lon.isFinite && (-90...90).contains(lat) && (-180...180).contains(lon),
                "Coordinates must have latitude between -90 and 90 and longitude between -180 and 180.")
    return CLLocation(latitude: lat, longitude: lon)
}

func appleMapsURL(title: String, location: CLLocation) -> String {
    var url = URLComponents(string: "https://maps.apple.com/")!
    url.queryItems = [URLQueryItem(name: "q", value: title),
        URLQueryItem(name: "ll", value: "\(location.coordinate.latitude),\(location.coordinate.longitude)")]
    return url.url!.absoluteString
}

func mapLocation(_ item: MKMapItem) -> CLLocation {
    if #available(macOS 26.0, *) { return item.location }
    return item.placemark.location ?? CLLocation(latitude: item.placemark.coordinate.latitude,
                                                longitude: item.placemark.coordinate.longitude)
}

func mapAddress(_ item: MKMapItem) -> String {
    if #available(macOS 26.0, *) {
        return item.address?.fullAddress ?? item.addressRepresentations?.fullAddress(includingRegion: true, singleLine: true) ?? ""
    }
    return item.placemark.title ?? ""
}

func structuredLocationOutput(_ location: EKStructuredLocation) -> [String: Any] {
    var result: [String: Any] = ["title": location.title ?? "", "radius_meters": location.radius,
                                "has_coordinates": location.geoLocation != nil]
    if let point = location.geoLocation {
        result["latitude"] = point.coordinate.latitude
        result["longitude"] = point.coordinate.longitude
        result["apple_maps_url"] = appleMapsURL(title: location.title ?? "", location: point)
    }
    return result
}

final class PlaceService {
    struct CachedPlace {
        let item: MKMapItem
        let expires: Date
    }
    var cache: [String: CachedPlace] = [:]

    func remember(_ item: MKMapItem) -> String {
        cache = cache.filter { $0.value.expires > Date() }
        while cache.count >= 256, let oldest = cache.min(by: { $0.value.expires < $1.value.expires }) {
            cache.removeValue(forKey: oldest.key)
        }
        let ref = "ap1." + UUID().uuidString.lowercased()
        cache[ref] = CachedPlace(item: item, expires: Date().addingTimeInterval(1800))
        return ref
    }

    func mapItem(_ reference: String) throws -> MKMapItem {
        guard let place = cache[reference], place.expires > Date() else {
            cache.removeValue(forKey: reference)
            throw CalendarFailure("place_reference_expired", "The selected place is unavailable or its 30-minute reference expired. Run search_places again; no event changes were saved.")
        }
        return place.item
    }

    func nativeLocation(_ reference: String) throws -> EKStructuredLocation {
        // Preserve the original Apple Maps item, including its native place metadata.
        return EKStructuredLocation(mapItem: try mapItem(reference))
    }

    func awaitItems(_ label: String, timeout: Double = 15,
                    start: @escaping (@escaping (Result<[MKMapItem], Error>) -> Void) -> (() -> Void)) throws -> [MKMapItem] {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[MKMapItem], Error>?
        var cancel: (() -> Void)?
        DispatchQueue.main.async {
            cancel = start { outcome in result = outcome; semaphore.signal() }
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            DispatchQueue.main.async { cancel?() }
            throw CalendarFailure("place_search_timeout", "\(label) timed out. Apple Maps requires an internet connection; retry the search.")
        }
        do { return try result!.get() }
        catch { throw CalendarFailure("place_search_failed", "\(label): \(error.localizedDescription)") }
    }

    func geocode(_ address: String) throws -> [MKMapItem] {
        return try awaitItems("Address lookup") { completion in
            if #available(macOS 26.0, *) {
                guard let request = MKGeocodingRequest(addressString: address) else {
                    completion(.success([])); return {}
                }
                request.getMapItems { items, error in
                    if let error = error { completion(.failure(error)) }
                    else { completion(.success(items ?? [])) }
                }
                return { request.cancel() }
            } else {
                let geocoder = CLGeocoder()
                geocoder.geocodeAddressString(address) { placemarks, error in
                    if let error = error { completion(.failure(error)) }
                    else {
                        let items = (placemarks ?? []).map { placemark in
                            let item = MKMapItem(placemark: MKPlacemark(placemark: placemark))
                            item.name = placemark.name
                            return item
                        }
                        completion(.success(items))
                    }
                }
                return { geocoder.cancelGeocode() }
            }
        }
    }

    func search(_ args: [String: Any]) throws -> [String: Any] {
        try require(!(args["near_address"] != nil && args["near_coordinates"] != nil),
                    "Provide near_address or near_coordinates, not both.")
        var origin: CLLocation?
        var originInfo: [String: Any]?
        if let point = args["near_coordinates"] as? [String: Any] {
            origin = try coordinates(point)
            originInfo = ["basis": "provided_coordinates"]
        } else if let address = args["near_address"] as? String {
            let candidates = try geocode(address)
            guard let first = candidates.first else {
                throw CalendarFailure("origin_not_found", "The reference address could not be located. Include a town and country, or provide coordinates.")
            }
            let location = mapLocation(first)
            if candidates.dropFirst().contains(where: { mapLocation($0).distance(from: location) > 1000 }) {
                throw CalendarFailure("origin_ambiguous", "The reference address matches multiple locations. Include a more specific address, town and country, or provide coordinates.")
            }
            origin = location
            originInfo = ["basis": "geocoded_address", "query": address, "resolved_address": mapAddress(first),
                          "precision_note": "A postcode or area may resolve to its center rather than a specific home or entrance."]
        }
        try require(args["radius_meters"] == nil || origin != nil,
                    "radius_meters requires near_address or near_coordinates.")
        let radius = (args["radius_meters"] as? NSNumber)?.doubleValue ?? 10000
        let query = args["query"] as! String
        let kind = args["result_type"] as? String ?? "all"
        let center = origin
        let items = try awaitItems("Place search") { completion in
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            switch kind {
            case "places": request.resultTypes = .pointOfInterest
            case "addresses": request.resultTypes = .address
            default: request.resultTypes = [.address, .pointOfInterest]
            }
            if let center = center {
                request.region = MKCoordinateRegion(center: center.coordinate, latitudinalMeters: radius * 2,
                                                    longitudinalMeters: radius * 2)
                if #available(macOS 15.0, *) { request.regionPriority = .required }
            }
            let search = MKLocalSearch(request: request)
            search.start { response, error in
                if let error = error { completion(.failure(error)) }
                else { completion(.success(response?.mapItems ?? [])) }
            }
            return { search.cancel() }
        }
        var seen = Set<String>()
        var candidates = items.filter { item in
            let location = mapLocation(item)
            guard CLLocationCoordinate2DIsValid(location.coordinate), !item.isCurrentLocation else { return false }
            if let origin = origin, location.distance(from: origin) > radius { return false }
            let key = "\(item.name ?? "")|\(location.coordinate.latitude)|\(location.coordinate.longitude)"
            return seen.insert(key).inserted
        }
        if let origin = origin {
            candidates.sort { mapLocation($0).distance(from: origin) < mapLocation($1).distance(from: origin) }
        }
        let places: [[String: Any]] = candidates.prefix(args["limit"] as? Int ?? 5).map { item in
            let location = mapLocation(item)
            var output: [String: Any] = ["place_ref": remember(item), "name": item.name ?? "",
                "address": mapAddress(item), "latitude": location.coordinate.latitude,
                "longitude": location.coordinate.longitude,
                "apple_maps_url": appleMapsURL(title: item.name ?? "", location: location)]
            if let origin = origin { output["distance_meters"] = location.distance(from: origin).rounded() }
            if #available(macOS 15.0, *), let id = item.identifier { output["provider_place_id"] = id.rawValue }
            return output
        }
        var output: [String: Any] = ["places": places, "provider": "Apple Maps / MapKit",
            "query": query, "sort_order": origin == nil ? "provider_relevance" : "straight_line_distance",
            "returned_count": places.count, "matched_count": candidates.count,
            "reference_validity": "place_ref lasts 30 minutes in this plugin connection. Use it unchanged in create_event or update_event.",
            "coverage_note": "Results depend on Apple Maps coverage. Match the requested venue or building explicitly; a campus or street result does not confirm a specific building or entrance. Distances are straight-line estimates, not walking or driving routes."]
        if let origin = origin {
            originInfo?["latitude"] = origin.coordinate.latitude
            originInfo?["longitude"] = origin.coordinate.longitude
            output["origin"] = originInfo
            output["radius_meters"] = radius
        }
        return output
    }
}

func editLocation(_ event: EKEvent, _ args: [String: Any], places: PlaceService) throws {
    let supplied = ["location", "place_ref", "structured_location"].filter { args[$0] != nil }
    try require(supplied.count <= 1, "Supply only one of location, place_ref, or structured_location.")
    if let reference = args["place_ref"] as? String {
        event.structuredLocation = try places.nativeLocation(reference)
    } else if let data = args["structured_location"] as? [String: Any] {
        let native = EKStructuredLocation(title: data["title"] as! String)
        native.geoLocation = try coordinates(data)
        native.radius = (data["radius_meters"] as? NSNumber)?.doubleValue ?? 0
        event.structuredLocation = native
    } else if let text = args["location"] as? String {
        // Clear old coordinates and native place metadata when switching to plain text.
        event.structuredLocation = nil
        event.location = text.isEmpty ? nil : text
    }
}
