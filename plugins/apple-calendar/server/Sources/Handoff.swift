import Foundation
import AppKit
import EventKit
import MapKit

func onMain<T>(_ body: () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try body() }
    return try DispatchQueue.main.sync(execute: body)
}

// Values are passed as typed Apple event arguments, never interpolated into source.
let calendarShowScript = """
on run arguments
    set calendarKey to item 1 of arguments
    set eventKey to item 2 of arguments
    set occurrenceDate to item 3 of arguments
    set currentStage to "calendar lookup"
    try
    tell application id "com.apple.iCal"
        with timeout of 20 seconds
            set targetCalendar to calendar id calendarKey
            set currentStage to "event lookup"
            set matchingEvents to every event of targetCalendar whose uid is eventKey
            if (count of matchingEvents) is not 1 then return "event_not_found"
            set currentStage to "date navigation"
            view calendar at occurrenceDate
            set currentStage to "event display"
            show item 1 of matchingEvents
            activate
        end timeout
    end tell
    on error errorText number errorCode
        error (currentStage & ": " & errorText) number errorCode
    end try
    return "opened"
end run
"""

func showCalendarEvent(_ event: EKEvent) throws -> [String: Any] {
    // Calendar's scripting UID is the local item identity, not the server's iCalendar UID.
    let uid = event.calendarItemIdentifier
    let calendarID = event.calendar.calendarIdentifier
    let date = event.startDate!
    let opened: String = try onMain {
        guard let script = NSAppleScript(source: calendarShowScript) else {
            throw CalendarFailure("handoff_failed", "The native Calendar script could not be compiled.")
        }
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: calendarID), at: 1)
        arguments.insert(NSAppleEventDescriptor(string: uid), at: 2)
        arguments.insert(NSAppleEventDescriptor(date: date), at: 3)
        let request = NSAppleEventDescriptor(eventClass: 0x61657674, eventID: 0x6F617070,
            targetDescriptor: nil, returnID: -1, transactionID: 0)
        request.setParam(arguments, forKeyword: 0x2D2D2D2D)
        var error: NSDictionary?
        let result = script.executeAppleEvent(request, error: &error)
        if let error = error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 {
                throw CalendarFailure("automation_access_required", "Allow Apple Calendar Plugin or its responsible host to control Calendar in System Settings > Privacy & Security > Automation, then retry open_event. Calendar data access and Automation are separate permissions.")
            }
            let detail = error[NSAppleScript.errorMessage] as? String ?? "Unknown Apple event error"
            throw CalendarFailure("handoff_failed", "Calendar could not show the event (Apple event error \(code)): \(detail). No calendar data was changed.")
        }
        return result.stringValue ?? ""
    }
    guard opened == "opened" else {
        throw CalendarFailure("native_event_not_found", "Calendar could not uniquely match this event in its exact calendar (\(opened)). Refresh sync and read it again; no title-based fallback was used.")
    }
    return ["opened": true, "application": "Calendar", "data_changed": false,
            "occurrence_note": "Calendar's native show command controls the detail window; recurring events may display their series. The requested date was also passed to the calendar view."]
}

func openMaps(destination: MKMapItem, origin: MKMapItem?, mode: String?) throws -> [String: Any] {
    var options: [String: Any] = [:]
    if let mode = mode {
        let modes = ["walking": MKLaunchOptionsDirectionsModeWalking, "driving": MKLaunchOptionsDirectionsModeDriving,
                     "transit": MKLaunchOptionsDirectionsModeTransit, "cycling": MKLaunchOptionsDirectionsModeCycling]
        options[MKLaunchOptionsDirectionsModeKey] = modes[mode]!
    }
    let items = origin.map { [$0, destination] } ?? [destination]
    let opened = onMain { MKMapItem.openMaps(with: items, launchOptions: options) }
    guard opened else { throw CalendarFailure("handoff_failed", "macOS could not open the requested location in Maps.") }
    return ["opened": true, "application": "Maps", "data_changed": false,
            "origin_note": origin == nil && mode != nil ? "Maps chooses the starting point; the plugin does not read device location." : "Uses the provided map locations."]
}
