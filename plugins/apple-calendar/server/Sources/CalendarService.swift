import Foundation
import EventKit

func exclusiveEnd(_ event: EKEvent) -> Date {
    guard event.isAllDay else { return event.endDate }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let midnight = calendar.startOfDay(for: event.endDate)
    if abs(event.endDate.timeIntervalSince(midnight)) < 0.01 { return event.endDate }
    // macOS EventKit returns an inclusive 23:59:59 end for all-day events.
    return calendar.date(byAdding: .day, value: 1, to: midnight)!
}

final class CalendarService {
    lazy var store = EKEventStore()
    let places = PlaceService()

    func status() -> [String: Any] {
        let state = EKEventStore.authorizationStatus(for: .event)
        let label: String
        switch state {
        case .notDetermined: label = "not_determined"
        case .restricted: label = "restricted"
        case .denied: label = "denied"
        case .fullAccess: label = "full_access"
        case .writeOnly: label = "write_only"
        @unknown default: label = "unknown"
        }
        return ["authorization": label, "connected": state == .fullAccess,
                "time_zone": TimeZone.current.identifier, "now": timestamp(Date()),
                "platform": "macOS", "version": pluginVersion,
                "permission_help": "Use request_access for the native prompt. If denied, enable Calendars > Full Access for Apple Calendar or the responsible host app in System Settings > Privacy & Security, then reconnect the plugin."]
    }

    func access() throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CalendarFailure("calendar_access_required", "Calendar full access is required. Call request_access and let the person respond to macOS. If previously denied, use System Settings > Privacy & Security > Calendars.")
        }
    }

    func authorize() throws -> [String: Any] {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return status() }
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        var failure: Error?
        store.requestFullAccessToEvents { allowed, error in
            granted = allowed; failure = error; semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 120) == .success else {
            throw CalendarFailure("permission_pending", "macOS permission is still pending. Respond to the native prompt, then retry calendar_status.")
        }
        if let failure = failure { throw failure }
        guard granted else { throw CalendarFailure("calendar_access_denied", "macOS did not grant calendar full access. Enable it in System Settings > Privacy & Security > Calendars.") }
        store.reset()
        return status()
    }

    func calendars() -> [EKCalendar] {
        store.calendars(for: .event).sorted {
            ($0.source.title, $0.title, $0.calendarIdentifier) < ($1.source.title, $1.title, $1.calendarIdentifier)
        }
    }

    func calendar(_ id: String, writable: Bool = false) throws -> EKCalendar {
        guard let result = calendars().first(where: { $0.calendarIdentifier == id }) else {
            throw CalendarFailure("calendar_not_found", "Calendar id no longer exists. Call list_calendars for a current id.")
        }
        if writable && !result.allowsContentModifications {
            throw CalendarFailure("read_only_calendar", "This calendar is read-only or subscribed. Select a writable calendar in the intended account.")
        }
        return result
    }

    func selectedCalendars(_ args: [String: Any]) throws -> [EKCalendar]? {
        guard let ids = args["calendar_ids"] as? [String] else { return nil }
        return try ids.map { try calendar($0) }
    }

    func listCalendars() -> [String: Any] {
        let defaultID = store.defaultCalendarForNewEvents?.calendarIdentifier
        let items = calendars().map { c -> [String: Any] in
            var result: [String: Any] = ["id": c.calendarIdentifier, "title": c.title,
                "account": c.source.title, "source_id": c.source.sourceIdentifier,
                "source_type": sourceType(c.source.sourceType),
                "writable": c.allowsContentModifications, "subscribed": c.isSubscribed,
                "is_default": c.calendarIdentifier == defaultID]
            if let color = c.cgColor, let components = color.components { result["color_components"] = components }
            return result
        }
        return ["calendars": items, "time_zone": TimeZone.current.identifier]
    }

    func sourceType(_ type: EKSourceType) -> String {
        switch type {
        case .local: return "local"
        case .exchange: return "exchange"
        case .calDAV: return "caldav"
        case .mobileMe: return "icloud"
        case .subscribed: return "subscribed"
        case .birthdays: return "birthdays"
        @unknown default: return "unknown"
        }
    }

    func reference(_ event: EKEvent) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["v": 1,
            "calendar": event.calendar.calendarIdentifier, "item": event.calendarItemIdentifier,
            "start": event.startDate.timeIntervalSince1970, "end": event.endDate.timeIntervalSince1970], options: [.sortedKeys])
        return "ac1." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func resolve(_ ref: String) throws -> EKEvent {
        try require(ref.hasPrefix("ac1.") && ref.count < 8192, "Invalid event_ref. Use a reference returned by this plugin.")
        var encoded = String(ref.dropFirst(4)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["v"] as? Int == 1, let cal = object["calendar"] as? String,
              let item = object["item"] as? String, let epoch = object["start"] as? Double, epoch.isFinite,
              epoch > -62135596800 && epoch < 253402300800 else {
            throw CalendarFailure("invalid_arguments", "Invalid event_ref payload.")
        }
        let selected = try calendar(cal)
        let start = Date(timeIntervalSince1970: epoch)
        let predicate = store.predicateForEvents(withStart: start.addingTimeInterval(-1), end: start.addingTimeInterval(1), calendars: [selected])
        let matches = store.events(matching: predicate).filter {
            $0.calendarItemIdentifier == item && abs($0.startDate.timeIntervalSince(start)) < 0.01
        }
        guard matches.count == 1, let event = matches.first else {
            throw CalendarFailure("stale_event_reference", "The exact occurrence was moved, removed or changed by sync. Search again and use the new event_ref. No changes were saved.")
        }
        return event
    }

    func participant(_ p: EKParticipant) -> [String: Any] {
        ["name": p.name ?? "", "url": p.url.absoluteString,
         "is_current_user": p.isCurrentUser, "status": p.participantStatus.rawValue,
         "role": p.participantRole.rawValue]
    }

    func serialize(_ event: EKEvent, details: Bool = true) -> [String: Any] {
        let tz = event.timeZone ?? .current
        let end = exclusiveEnd(event)
        var result: [String: Any] = ["event_ref": reference(event), "title": event.title ?? "",
            "calendar_id": event.calendar.calendarIdentifier, "calendar": event.calendar.title,
            "account": event.calendar.source.title,
            "start": event.isAllDay ? dayString(event.startDate, in: tz) : timestamp(event.startDate, in: tz),
            "end": event.isAllDay ? dayString(end, in: tz) : timestamp(end, in: tz),
            "start_instant": timestamp(event.startDate), "end_instant": timestamp(end),
            "all_day": event.isAllDay, "time_zone": tz.identifier, "floating_time": event.timeZone == nil,
            "availability": availabilityName(event.availability), "status": event.status.rawValue,
            "recurring": event.hasRecurrenceRules, "detached_occurrence": event.isDetached,
            "writable": event.calendar.allowsContentModifications && (event.attendees ?? []).isEmpty]
        if let location = event.location { result["location"] = location }
        if let location = event.structuredLocation { result["structured_location"] = structuredLocationOutput(location) }
        if let notes = event.notes { result["notes"] = notes }
        if let url = event.url { result["url"] = url.absoluteString }
        if let changed = event.lastModifiedDate { result["last_modified"] = timestamp(changed) }
        if details {
            if event.hasRecurrenceRules && !event.isDetached,
               let first = store.calendarItem(withIdentifier: event.calendarItemIdentifier) as? EKEvent,
               first.calendar.calendarIdentifier == event.calendar.calendarIdentifier {
                result["series_first_event_ref"] = reference(first)
                result["series_first_start"] = first.isAllDay ? dayString(first.startDate, in: tz) : timestamp(first.startDate, in: tz)
                result["series_first_end"] = first.isAllDay ? dayString(exclusiveEnd(first), in: tz) : timestamp(exclusiveEnd(first), in: tz)
            }
            result["attendees"] = (event.attendees ?? []).map(participant)
            if let p = event.organizer { result["organizer"] = participant(p) }
            result["reminders"] = (event.alarms ?? []).map { alarm -> [String: Any] in
                if let absolute = alarm.absoluteDate { return ["at": timestamp(absolute)] }
                return ["minutes_before": -alarm.relativeOffset / 60]
            }
            result["recurrence_rules"] = (event.recurrenceRules ?? []).map(recurrenceOutput)
        }
        return result
    }

    func availabilityName(_ value: EKEventAvailability) -> String {
        switch value {
        case .busy: return "busy"
        case .free: return "free"
        case .tentative: return "tentative"
        case .unavailable: return "unavailable"
        case .notSupported: return "unknown"
        @unknown default: return "unknown"
        }
    }

    func events(_ args: [String: Any]) throws -> [EKEvent] {
        let (start, end, _) = try range(args)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: try selectedCalendars(args))
        return store.events(matching: predicate).filter { $0.startDate < end && exclusiveEnd($0) > start }
            .sorted { ($0.startDate!, $0.calendar.calendarIdentifier, $0.calendarItemIdentifier) < ($1.startDate!, $1.calendar.calendarIdentifier, $1.calendarItemIdentifier) }
    }

    func listEvents(_ args: [String: Any]) throws -> [String: Any] {
        var matches = try events(args)
        if let query = args["query"] as? String {
            matches = matches.filter { event in
                [event.title, event.location, event.notes].compactMap { $0 }.contains {
                    $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
            }
        }
        let offset = args["offset"] as? Int ?? 0
        let limit = args["limit"] as? Int ?? 50
        let page = Array(matches.dropFirst(offset).prefix(limit))
        let more = offset + page.count < matches.count
        var output: [String: Any] = ["events": page.map { serialize($0) }, "total": matches.count,
            "offset": offset, "has_more": more, "time_zone": try zone(args).identifier,
            "sync_note": "Results reflect the calendar data currently synced to this Mac."]
        if more { output["next_offset"] = offset + page.count }
        return output
    }

    func recurrence(_ args: [String: Any], start: Date, tz: TimeZone) throws -> EKRecurrenceRule {
        try makeRecurrence(args, start: start, tz: tz)
    }

    func edit(_ event: EKEvent, _ args: [String: Any], creating: Bool) throws {
        let allDay = args["all_day"] as? Bool ?? event.isAllDay
        let requestedZone = try args["time_zone"] != nil ? zone(args) : (creating ? TimeZone.current : event.timeZone ?? .current)
        // All-day dates float in the system time zone regardless of a supplied timed zone.
        let tz = allDay ? TimeZone.current : requestedZone
        if !creating && (allDay != event.isAllDay || (allDay && args["time_zone"] != nil)) {
            try require(args["start"] != nil && args["end"] != nil, "Changing all_day or an all-day time zone requires both start and end.")
        }
        let start = try (args["start"] as? String).map { try parseDate($0, in: tz, allDay: allDay) } ?? event.startDate!
        let end = try (args["end"] as? String).map { try parseDate($0, in: tz, allDay: allDay) } ?? exclusiveEnd(event)
        try require(end > start, "end must be later than start; all-day end is exclusive.")
        if let title = args["title"] as? String { event.title = title }
        // A non-nil time zone turns all-day mode off on macOS; set the mode afterward.
        if !allDay && (creating || args["time_zone"] != nil) { event.timeZone = tz }
        event.isAllDay = allDay
        event.startDate = start
        event.endDate = allDay ? end.addingTimeInterval(-1) : end
        try editLocation(event, args, places: places)
        if let notes = args["notes"] as? String { event.notes = notes.isEmpty ? nil : notes }
        if let url = args["url"] as? String {
            if url.isEmpty { event.url = nil }
            else {
                guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
                      ["https", "http"].contains(scheme), parsed.host != nil else {
                    throw CalendarFailure("invalid_arguments", "url must be an absolute HTTP(S) URL.")
                }
                event.url = parsed
            }
        }
        if let availability = args["availability"] as? String {
            let value: EKEventAvailability
            let mask: EKCalendarEventAvailabilityMask
            switch availability {
            case "free": value = .free; mask = .free
            case "tentative": value = .tentative; mask = .tentative
            case "unavailable": value = .unavailable; mask = .unavailable
            default: value = .busy; mask = .busy
            }
            try require(event.calendar.supportedEventAvailabilities.contains(mask), "This calendar does not support the requested availability.")
            event.availability = value
        }
        if let minutes = args["reminder_minutes"] as? [Int] {
            event.alarms = minutes.map { EKAlarm(relativeOffset: Double(-$0 * 60)) }
        }
        if let rule = args["recurrence"] as? [String: Any] {
            event.recurrenceRules = [try recurrence(rule, start: start, tz: tz)]
        }
        if args["clear_recurrence"] as? Bool == true { event.recurrenceRules = nil }
    }

    func span(_ event: EKEvent, _ args: [String: Any]) throws -> EKSpan {
        if event.hasRecurrenceRules || event.isDetached {
            try require(args["scope"] != nil, "For a recurring event, specify scope=this_event, future_events or entire_series explicitly.")
        }
        return ["future_events", "entire_series"].contains(args["scope"] as? String ?? "") ? .futureEvents : .thisEvent
    }

    func writable(_ event: EKEvent) throws {
        _ = try calendar(event.calendar.calendarIdentifier, writable: true)
        if !(event.attendees ?? []).isEmpty {
            throw CalendarFailure("meeting_changes_unsupported", "This event has attendees. Edit or respond in Apple Calendar; this plugin does not send meeting invitations, cancellations or responses.")
        }
    }

    func seriesTarget(_ event: EKEvent, _ args: [String: Any]) throws -> EKEvent {
        guard args["scope"] as? String == "entire_series" else { return event }
        try require(event.hasRecurrenceRules && !event.isDetached,
                    "Entire-series changes require a non-detached recurring occurrence. Read an unchanged occurrence first.")
        // EventKit documents this lookup as returning the first occurrence.
        guard let first = store.calendarItem(withIdentifier: event.calendarItemIdentifier) as? EKEvent,
              first.calendar.calendarIdentifier == event.calendar.calendarIdentifier,
              first.calendarItemExternalIdentifier == event.calendarItemExternalIdentifier,
              first.hasRecurrenceRules, !first.isDetached else {
            throw CalendarFailure("series_not_resolved", "The first occurrence could not be verified. No series changes were saved.")
        }
        return first
    }

    func verifySaved(_ event: EKEvent, scope: String?) -> [String: Any] {
        let snapshot = serialize(event)
        let ref = reference(event)
        let point = event.structuredLocation?.geoLocation
        var output: [String: Any] = ["saved": true, "event": snapshot,
            "sync_note": "Saved to the local calendar database. Remote account and other-device sync are managed by macOS and are not verified here."]
        if let scope = scope { output["scope"] = scope }
        store.reset()
        do {
            let fetched = try resolve(ref)
            output["event"] = serialize(fetched)
            var verification: [String: Any] = ["read_back_verified": true, "native_coordinates_expected": point != nil]
            if let point = point {
                let matches = fetched.structuredLocation?.geoLocation.map { $0.distance(from: point) < 2 } ?? false
                verification["native_location_verified"] = matches
                if !matches { output["warning"] = "The event was saved, but its native coordinates did not survive read-back. Do not create a duplicate; inspect or update the saved event." }
            }
            output["persistence"] = verification
        } catch {
            output["persistence"] = ["read_back_verified": false]
            output["warning"] = "Save succeeded but immediate read-back could not resolve the occurrence. Search the affected range before retrying any create operation."
        }
        return output
    }

    func freeTime(_ args: [String: Any]) throws -> [String: Any] {
        let (start, end, tz) = try range(args)
        try require(end.timeIntervalSince(start) <= 31 * 86400, "Free-time windows must not exceed 31 days.")
        let matches = try events(args).filter(isBusy)
        let busy = mergeIntervals(matches.map { ($0.startDate, exclusiveEnd($0)) }, start: start, end: end)
        let free = freeIntervals(busy, start: start, end: end, minimum: Double(args["minimum_minutes"] as? Int ?? 30) * 60)
        func output(_ intervals: [(Date, Date)]) -> [[String: Any]] {
            intervals.map { ["start": timestamp($0.0, in: tz), "end": timestamp($0.1, in: tz),
                              "minutes": $0.1.timeIntervalSince($0.0) / 60] }
        }
        return ["busy": output(busy), "free": output(free), "time_zone": tz.identifier,
                "coverage": "Only calendars and events synced to this Mac. No remote attendee availability is queried."]
    }

    func call(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
        guard let tool = tools.first(where: { $0.name == name }) else { throw CalendarFailure("unknown_tool", "Unknown tool: \(name)") }
        try validate(args, schema: tool.schema)
        if name == "calendar_status" { return status() }
        if name == "request_access" { return try authorize() }
        if name == "search_places" { return try places.search(args) }
        if name == "calculate_route" || name == "open_in_maps" {
            let endpoints = [args["origin"], args["destination"]].compactMap { $0 as? [String: Any] }
            if endpoints.contains(where: { $0["event_ref"] != nil }) { try access(); store.reset() }
            if name == "calculate_route" { return try calculateRoute(args) }
            let destination = try endpoint(args["destination"] as! [String: Any]).0
            let origin = try (args["origin"] as? [String: Any]).map { try endpoint($0).0 }
            try require(origin == nil || args["transport_type"] != nil, "Provide transport_type when opening directions from an origin.")
            return try openMaps(destination: destination, origin: origin, mode: args["transport_type"] as? String)
        }
        try access()
        // Refresh external sync changes before every operation; calls are serialized.
        store.reset()
        switch name {
        case "list_calendars": return listCalendars()
        case "list_events", "search_events": return try listEvents(args)
        case "get_event": return ["event": serialize(try resolve(args["event_ref"] as! String))]
        case "find_free_time": return try freeTime(args)
        case "open_event": return try showCalendarEvent(resolve(args["event_ref"] as! String))
        case "check_travel_feasibility": return try travelFeasibility(args)
        case "create_event":
            let event = EKEvent(eventStore: store)
            event.calendar = try calendar(args["calendar_id"] as! String, writable: true)
            try edit(event, args, creating: true)
            try store.save(event, span: .thisEvent, commit: true)
            return verifySaved(event, scope: nil)
        case "update_event":
            let selected = try resolve(args["event_ref"] as! String)
            try writable(selected)
            let scope = try span(selected, args)
            let event = try seriesTarget(selected, args)
            try writable(event)
            let changed = Set(args.keys).subtracting(["event_ref", "scope"])
            try require(!changed.isEmpty, "Supply at least one field to update.")
            try require(!(args["recurrence"] != nil && args["clear_recurrence"] as? Bool == true), "recurrence and clear_recurrence=true are mutually exclusive.")
            if args["recurrence"] != nil || args["clear_recurrence"] as? Bool == true {
                try require(scope == .futureEvents || !(event.hasRecurrenceRules || event.isDetached), "Changing a recurring rule requires scope=future_events.")
            }
            if let id = args["calendar_id"] as? String { event.calendar = try calendar(id, writable: true) }
            try edit(event, args, creating: false)
            try store.save(event, span: scope, commit: true)
            return verifySaved(event, scope: args["scope"] as? String ?? "this_event")
        case "delete_event":
            let selected = try resolve(args["event_ref"] as! String)
            try writable(selected)
            let scope = try span(selected, args)
            let event = try seriesTarget(selected, args)
            try writable(event)
            let snapshot = serialize(event, details: false)
            try store.remove(event, span: scope, commit: true)
            return ["deleted": true, "event": snapshot, "scope": args["scope"] as? String ?? "this_event"]
        default: throw CalendarFailure("unknown_tool", "Unknown tool.")
        }
    }
}
