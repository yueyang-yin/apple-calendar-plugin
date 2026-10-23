import Foundation

struct Tool {
    let name: String
    let title: String
    let description: String
    let schema: [String: Any]
    let readOnly: Bool
    let destructive: Bool
    var definition: [String: Any] {
        ["name": name, "title": title, "description": description, "inputSchema": schema,
         "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive,
                         "idempotentHint": readOnly, "openWorldHint": true]]
    }
}

func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
    ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
}
func string(_ description: String, values: [String]? = nil, empty: Bool = false) -> [String: Any] {
    var result: [String: Any] = ["type": "string", "description": description]
    if !empty { result["minLength"] = 1 }
    if let values = values { result["enum"] = values }
    return result
}
func integer(_ description: String, _ min: Int, _ max: Int) -> [String: Any] {
    ["type": "integer", "description": description, "minimum": min, "maximum": max]
}
let timeZoneField = string("IANA time zone, e.g. Europe/London. Defaults to the Mac's current zone. All-day date-only values always float as local calendar dates.")
let timestampField = string("ISO 8601 timestamp with seconds and Z or a numeric UTC offset. End is exclusive.")
let calendarIDField = string("Exact calendar id returned by list_calendars. Never guess or match title alone.")
let eventRefField = string("Opaque occurrence reference returned by list_events, search_events, get_event or create_event. Use unchanged.")
let recurrenceField = object([
    "frequency": string("Recurrence frequency.", values: ["daily", "weekly", "monthly", "yearly"]),
    "interval": integer("Repeat every N units; defaults to 1.", 1, 99),
    "weekdays": ["type": "array", "description": "Weekday filters for weekly, monthly or yearly rules. 1 = Sunday, ..., 7 = Saturday. Mutually exclusive with ordinal_weekdays.",
                 "items": integer("Weekday.", 1, 7), "minItems": 1, "maxItems": 7, "uniqueItems": true],
    "ordinal_weekdays": ["type": "array", "description": "Monthly/yearly ordinal weekdays, such as the second Tuesday. Mutually exclusive with weekdays and days_of_month.",
        "items": object(["day": integer("1 = Sunday, ..., 7 = Saturday.", 1, 7),
                         "week_number": integer("Nonzero ordinal, negative counts from the end. Monthly range ±5, yearly ±53.", -53, 53)], required: ["day", "week_number"]),
        "minItems": 1, "maxItems": 14, "uniqueItems": true],
    "days_of_month": integerArray("Monthly day numbers, ±1...31; negative counts from month end. Zero is invalid.", -31, 31, 62),
    "months_of_year": integerArray("Yearly month filter, 1...12.", 1, 12, 12),
    "weeks_of_year": integerArray("Yearly week filter, ±1...53; zero is invalid.", -53, 53, 106),
    "days_of_year": integerArray("Yearly day filter, ±1...366; zero is invalid.", -366, 366, 366),
    "set_positions": integerArray("Positions in the filtered recurrence set, ±1...366; zero is invalid. For example weekdays Mon-Fri with [-1] selects the last weekday.", -366, 366, 366),
    "count": integer("Number of occurrences. Mutually exclusive with until.", 1, 10000),
    "until": timestampField
], required: ["frequency"])
func integerArray(_ description: String, _ minimum: Int, _ maximum: Int, _ count: Int) -> [String: Any] {
    ["type": "array", "description": description, "items": integer("Recurrence component.", minimum, maximum),
     "minItems": 1, "maxItems": count, "uniqueItems": true]
}
let remindersField: [String: Any] = ["type": "array", "description": "Minutes before the start; 0 means at start. Empty array clears reminders.",
                                    "items": integer("Minutes before event.", 0, 40320), "maxItems": 5, "uniqueItems": true]
let coordinateFields: [String: Any] = [
    "latitude": ["type": "number", "minimum": -90, "maximum": 90, "description": "Latitude in degrees."],
    "longitude": ["type": "number", "minimum": -180, "maximum": 180, "description": "Longitude in degrees."]
]
let coordinatesField = object(coordinateFields, required: ["latitude", "longitude"])
let structuredLocationField = object(fields(coordinateFields, [
    "title": string("Verified location label or full address to display in the calendar."),
    "radius_meters": ["type": "number", "minimum": 0, "maximum": 100000, "description": "Location radius in meters, default 0."]
]), required: ["title", "latitude", "longitude"])
let endpointField = object([
    "place_ref": string("Unchanged search_places reference, valid for 30 minutes in this connection."),
    "event_ref": eventRefField,
    "coordinates": object(fields(coordinateFields, ["title": string("Optional verified location label.")]), required: ["latitude", "longitude"])
])
let transportField = string("Transportation mode, default walking. Availability depends on Apple Maps coverage.", values: ["walking", "driving", "transit", "cycling"])
let journeyFields: [String: Any] = ["origin": endpointField, "destination": endpointField,
    "transport_type": transportField, "time_zone": timeZoneField]
let scopeField = string("Required for recurring events: this_event, future_events or entire_series. Entire series targets the verified first occurrence; detached instances are rejected.", values: ["this_event", "future_events", "entire_series"])
let sharedEventFields: [String: Any] = [
    "title": string("Event title."),
    "start": string("Timed: offset-qualified ISO 8601. All-day: YYYY-MM-DD."),
    "end": string("Exclusive end. Timed: offset-qualified ISO 8601. All-day: YYYY-MM-DD of the following day or later."),
    "time_zone": timeZoneField,
    "all_day": ["type": "boolean", "description": "Whether the event occupies whole calendar days."],
    "location": string("Plain text location only. Empty string clears both text and native map location. Mutually exclusive with place_ref and structured_location.", empty: true),
    "place_ref": string("Exact Apple Maps result from search_places, valid for 30 minutes in this connection. Saves the native map place directly. Mutually exclusive with location and structured_location."),
    "structured_location": structuredLocationField,
    "notes": string("Notes. Empty string clears them.", empty: true),
    "url": string("HTTP(S) event URL. Empty string clears it.", empty: true),
    "availability": string("Busy status.", values: ["busy", "free", "tentative", "unavailable"]),
    "reminder_minutes": remindersField,
    "recurrence": recurrenceField
]
let queryFields: [String: Any] = [
    "start": timestampField, "end": timestampField, "time_zone": timeZoneField,
    "calendar_ids": ["type": "array", "items": calendarIDField, "minItems": 1, "maxItems": 100, "uniqueItems": true]
]
func fields(_ base: [String: Any], _ extra: [String: Any]) -> [String: Any] { base.merging(extra) { _, new in new } }

let tools: [Tool] = [
    Tool(name: "calendar_status", title: "Calendar connection status",
         description: "Check macOS calendar permission, current time and time zone without requesting access or reading calendars.",
         schema: object([:]), readOnly: true, destructive: false),
    Tool(name: "request_access", title: "Authorize Apple Calendar",
         description: "Request macOS full calendar access. The person must answer the native system prompt. Does not modify events.",
         schema: object([:]), readOnly: true, destructive: false),
    Tool(name: "list_calendars", title: "List calendars and accounts",
         description: "List calendars visible to EventKit, their account/source, exact ids, read-only status and default. Requires access; call request_access first if needed.",
         schema: object([:]), readOnly: true, destructive: false),
    Tool(name: "search_places", title: "Find places and addresses in Apple Maps",
         description: "Search any named venue, campus building, business or address through native Apple Maps. Returns coordinates and place_ref for direct native calendar locations. Supply a self-contained query; optionally use near_address or near_coordinates for proximity ranking. Does not use device location, modify events or operate the UI. Results may require disambiguation; internet access is required.",
         schema: object([
            "query": string("Place name, building name or address. Include town, campus or country when needed for disambiguation."),
            "near_address": string("Optional reference address or postcode with town/country. Resolved by Apple Maps; mutually exclusive with near_coordinates."),
            "near_coordinates": coordinatesField,
            "radius_meters": integer("Optional maximum distance from the reference point, default 10000. Requires near_address or near_coordinates.", 100, 100000),
            "result_type": string("Search addresses, points of interest, or both (default all).", values: ["all", "places", "addresses"]),
            "limit": integer("Maximum returned candidates, default 5.", 1, 20)
         ], required: ["query"]), readOnly: true, destructive: false),
    Tool(name: "list_events", title: "List calendar events",
         description: "List expanded occurrences overlapping a bounded time window (up to 366 days). Pagination has_more/next_offset; all calendars unless calendar_ids supplied. Does not request permission automatically.",
         schema: object(fields(queryFields, ["limit": integer("Page size, default 50.", 1, 200), "offset": integer("Result offset, default 0.", 0, 100000)]), required: ["start", "end"]), readOnly: true, destructive: false),
    Tool(name: "search_events", title: "Search calendar events",
         description: "Case-insensitive literal search of title, location and notes inside a bounded time window. Returns expanded occurrences and pagination.",
         schema: object(fields(queryFields, ["query": string("Literal text to search."), "limit": integer("Page size, default 50.", 1, 200), "offset": integer("Result offset, default 0.", 0, 100000)]), required: ["start", "end", "query"]), readOnly: true, destructive: false),
    Tool(name: "get_event", title: "Read an event occurrence",
         description: "Read an exact event occurrence, recurrence, reminders and read-only attendee information. If an event moved, search again for a fresh reference.",
         schema: object(["event_ref": eventRefField], required: ["event_ref"]), readOnly: true, destructive: false),
    Tool(name: "open_event", title: "Show an event in Apple Calendar",
         description: "Open the exact calendar event in the native Calendar app using its system scripting interface. Changes focus only, not event data. Requires separate macOS Automation access to Calendar; never falls back to a title match. Recurring events may show their series.",
         schema: object(["event_ref": eventRefField], required: ["event_ref"]), readOnly: true, destructive: false),
    Tool(name: "open_in_maps", title: "Open a native place or directions in Apple Maps",
         description: "Open a destination in the native Maps app. Each endpoint needs exactly one place_ref, event_ref or coordinates object. Optionally provide origin and transport_type for directions. With a mode but no origin, Maps chooses the starting point; the plugin does not read GPS. Does not edit calendars.",
         schema: object(["destination": endpointField, "origin": endpointField, "transport_type": transportField], required: ["destination"]), readOnly: true, destructive: false),
    Tool(name: "calculate_route", title: "Estimate a journey using Apple Maps",
         description: "Estimate route distance and travel time between arbitrary verified places or event locations. Each endpoint needs exactly one place_ref, event_ref or coordinates. Optional depart_at or arrive_by, never both. No GPS or calendar changes. Unsupported routes fail explicitly rather than using straight-line time estimates.",
         schema: object(fields(journeyFields, ["depart_at": timestampField, "arrive_by": timestampField]), required: ["origin", "destination"]), readOnly: true, destructive: false),
    Tool(name: "check_travel_feasibility", title: "Check whether appointments leave enough travel time",
         description: "Check a journey and arrival buffer against available time and synced calendar conflicts, without changing events. Each endpoint needs exactly one place_ref, event_ref or coordinates. available_from defaults to a timed origin event's end; arrive_by defaults to a timed destination event's start. Planned places and all-day events require explicit boundaries. Does not reserve time or enable dynamic departure notifications.",
         schema: object(fields(journeyFields, ["available_from": timestampField, "arrive_by": timestampField,
             "buffer_minutes": integer("Extra arrival buffer, default 0.", 0, 1440),
             "calendar_ids": queryFields["calendar_ids"]!]), required: ["origin", "destination"]), readOnly: true, destructive: false),
    Tool(name: "create_event", title: "Create calendar event",
         description: "Create an event in an explicitly selected writable calendar. Use place_ref from search_places for a native Apple Maps location, or structured_location for verified coordinates. Also supports all-day dates, time zones, reminders and recurrence. Invitees cannot be added with EventKit.",
         schema: object(fields(sharedEventFields, ["calendar_id": calendarIDField]), required: ["calendar_id", "title", "start", "end"]), readOnly: false, destructive: false),
    Tool(name: "update_event", title: "Update calendar event",
         description: "Update specified fields of an exact occurrence; omitted fields, including native locations, are preserved. Use place_ref or structured_location to set a native map location. Recurring events require explicit scope. recurrence and clear_recurrence are mutually exclusive. Meeting invitations/responses are unsupported.",
         schema: object(fields(sharedEventFields, ["event_ref": eventRefField, "calendar_id": calendarIDField,
             "scope": scopeField,
             "clear_recurrence": ["type": "boolean", "description": "Remove recurrence; recurring events require future_events or entire_series."]]), required: ["event_ref"]), readOnly: false, destructive: true),
    Tool(name: "delete_event", title: "Delete calendar event",
         description: "Delete the exact referenced occurrence. Recurring events require explicit scope: this_event or future_events. Only call when the person requested deletion.",
         schema: object(["event_ref": eventRefField, "scope": scopeField] , required: ["event_ref"]), readOnly: false, destructive: true),
    Tool(name: "find_free_time", title: "Find local free time",
         description: "Compute busy intervals and free gaps from selected local calendars. Excludes cancelled, declined and free events; tentative/unknown availability blocks time. Limited to data synced to this Mac; does not query other people's server free/busy. Window max 31 days.",
         schema: object(fields(queryFields, ["minimum_minutes": integer("Minimum free gap, default 30.", 1, 44640)]), required: ["start", "end"]), readOnly: true, destructive: false)
]
