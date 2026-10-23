# Apple Calendar

A local Codex plugin for the native macOS calendar database, powered by Apple's EventKit framework. Includes a static calendar cover with a red header, white rounded square and neutral dot grid, without fixed dates or weekday labels.

## Requirements

- macOS 14 or newer, with a local Codex desktop session.
- The included executable is built for Apple Silicon. Rebuild on an Intel Mac using Xcode Command Line Tools.
- Full calendar access granted through the native macOS permission prompt.
- Calendar accounts configured and synced in Apple Calendar.

No Google OAuth, API key, hosted server, Node.js packages or Python packages are needed to run the plugin. Calendar data goes directly from EventKit to the local MCP client. The host may include tool results in the conversation according to its own data settings.

Optional place and address searches use Apple's native MapKit service and require internet access. Search queries and any reference address are sent to Apple Maps. The plugin does not request the device's current location.

## Install

Register the GitHub marketplace, then install the plugin:

```bash
codex plugin marketplace add https://github.com/yueyang-yin/apple-calendar-plugin.git --ref main
codex plugin add apple-calendar@apple-calendar-local
```

For a downloadable local marketplace, extract `Apple-Calendar-Marketplace-1.2.0.zip` from [GitHub Releases](https://github.com/yueyang-yin/apple-calendar-plugin/releases/latest), keep the extracted directory in a permanent location, and run:

```bash
codex plugin marketplace add /absolute/path/to/apple-calendar-marketplace
codex plugin add apple-calendar@apple-calendar-local
```

You can also select **Apple Calendar** from the **Apple Calendar Local** source in the desktop Plugins directory and install it there. If a running chat has not refreshed its tools, reopen the plugin or use a new local chat. Installing this local package does not deploy it to web or mobile.

`Apple-Calendar-1.2.0.zip` is the standalone plugin archive for clients that support plugin ZIP import. It contains one `apple-calendar/` root and no marketplace. If your app asks for a marketplace, use the GitHub source or marketplace ZIP instead. These downloads do not constitute publication in OpenAI's public plugin directory.

The bundled executable is Apple Silicon only, ad hoc signed, and not notarized. If macOS blocks a downloaded copy, review the source and rebuild on the target Mac using `bash scripts/build.sh` before installing. Do not disable Gatekeeper globally.

The plugin does not run directly in ChatGPT on iOS. A supported [remote connection](https://learn.chatgpt.com/docs/remote-connections) can let a phone work through an awake, online Mac, where the MCP process and calendar permissions remain. This mobile workflow has not been tested for this package.

The portable manifest is `plugin.json` with `mcp.json`. Compatibility manifests are also included for local Codex clients. The MCP server launches with `bash scripts/run.sh`, then runs the bundled signed native executable over standard input/output. The portable launcher uses a bare executable name because the Agent Plugins loader rejects absolute command paths.

## First use

1. Run `calendar_status`.
2. If necessary, run `request_access` and answer the native full-access prompt.
3. Run `list_calendars` to select the exact account and calendar.

If access was denied, use **System Settings > Privacy & Security > Calendars** and enable full access for the plugin or responsible host app shown there. Reconnect the plugin afterward. The plugin never resets privacy settings.

## Tools

| Tool | Behavior |
| --- | --- |
| `calendar_status` | Permission state, current time and Mac time zone |
| `request_access` | Native macOS calendar authorization |
| `list_calendars` | Accounts, calendar IDs, writability and default |
| `search_places` | Apple Maps venues, buildings and addresses with native place references and coordinates |
| `list_events` | Expanded event occurrences with pagination |
| `search_events` | Literal title, location and notes search |
| `get_event` | Exact occurrence, reminders, recurrence and attendee details |
| `open_event` | Show an exact saved event in the native Calendar app |
| `open_in_maps` | Show arbitrary locations or directions in the native Maps app |
| `calculate_route` | Apple Maps distance, ETA and departure/arrival estimates |
| `check_travel_feasibility` | Journey duration and arrival buffer checked against appointment gaps and conflicts |
| `create_event` | Save an event in an explicitly selected calendar |
| `update_event` | Change selected fields; preserve omitted fields |
| `delete_event` | Remove a selected occurrence or future occurrences |
| `find_free_time` | Merge local busy intervals and return free gaps |

Timed inputs require ISO 8601 timestamps including seconds and a UTC offset, such as `2026-10-23T09:00:00+01:00`. All-day inputs use floating `YYYY-MM-DD` local calendar dates and an exclusive end date. For a one-day event on October 23, supply October 24 as its end. macOS EventKit's inclusive all-day end is normalized by the server, including daylight-saving boundaries.

Supported recurrence frequencies are daily, weekly, monthly and yearly, with an interval, advanced filters, and an optional occurrence count or end timestamp. Existing rules are preserved when omitted. Recurring changes require an explicit `this_event`, `future_events` or `entire_series` scope. Entire-series operations resolve and verify the native first occurrence; detached exceptions are rejected for that scope. Event details expose `series_first_event_ref` and the first occurrence's dates. Start/end values on an entire-series update apply to that first occurrence, so preserve its date when changing the series' time of day.

Advanced recurrence inputs include:

- `weekdays`: weekday filters for weekly, monthly or yearly rules.
- `ordinal_weekdays`: monthly/yearly day and ordinal pairs, such as the second Tuesday or last Friday. Mutually exclusive with plain weekdays and specific month dates.
- `days_of_month`: positive month dates or negative offsets from month end, for monthly rules.
- `months_of_year`, `weeks_of_year`, `days_of_year`: yearly filters.
- `set_positions`: select positions after filtering. Monday-Friday plus `[-1]` selects the last calendar weekday of the month. Public-holiday exclusions are not inferred.

Zero is invalid in ordinal, signed date and position lists. Invalid or unsupported combinations fail before saving instead of silently losing filters. Rules are stored and expanded by EventKit, rather than materializing a separate event for every occurrence.

Each occurrence has an opaque `event_ref` containing its local identity and start instant. A moved or resynced occurrence may invalidate the reference; search again rather than guessing. Create calls are not idempotent: search before retrying a save with an uncertain result.

## Native map locations

The plugin supports arbitrary venues, buildings, businesses, addresses and verified coordinates. It does not hardcode particular destinations or phrases, and does not use UI automation to select a location.

1. Call `search_places` with a place name or address. Optionally use `near_address` or `near_coordinates` to constrain the area; `radius_meters` then defaults to 10,000. `result_type` can select places, addresses or both.
2. Review the candidates and pass the chosen `place_ref` unchanged to `create_event` or `update_event`. The server retains the original `MKMapItem` and converts it with `EKStructuredLocation(mapItem:)`, preserving the provider's native place metadata.
3. Inspect the save response's `persistence`: the server resets its EventKit store and reads the saved occurrence back. `read_back_verified` confirms that lookup, and `native_location_verified` checks expected coordinates within two meters. The returned event includes the actual persisted location, rather than only the in-memory edit. Remote synchronization is reported separately.

Place references expire after 30 minutes and are scoped to one server connection. Search again after expiry or reconnection. Up to 256 recent references are retained in memory; the plugin does not persist search history.

If Apple Maps has no exact result, `structured_location` accepts a title, verified latitude and longitude, and an optional radius. This produces a native map pin without claiming that Apple Maps has a business listing for it. The existing `location` input remains available for plain text; supplying an empty string clears all location data. These three inputs are mutually exclusive. Omitting them preserves the existing native location on unrelated edits.

Map coverage and query wording affect results. If a full query returns only a broad campus or street, retry the shorter destination name with a separate geographic reference. Verify ambiguous building abbreviations with an authoritative source, and never present a campus pin as an exact building. Multiple plausible destinations require disambiguation. Proximity results rank the returned matches by straight-line distance, not walking/driving time; a postcode may locate an area center rather than a home or entrance.

A successful save followed by a failed read-back returns `saved: true`, a verification warning and the saved event snapshot. Inspect/search before retrying a create, because this result does not mean that the save failed.

## Native application handoff

`open_event` uses Calendar's system scripting interface with the exact calendar ID and local item identity. It selects/shows the requested event and passes the occurrence date to Calendar's view. Calendar controls its own presentation; a recurring event may display the series. Calendar's scripting UID is the local EventKit item identity, not its server-provided iCalendar UID. No title matching or undocumented calendar URL scheme is used.

Showing events requires a separate macOS Automation permission to control Calendar. If denied, the tool returns the relevant **System Settings > Privacy & Security > Automation** guidance. This permission is separate from calendar data access. The plugin does not change privacy settings itself.

`open_in_maps` opens the native Maps app with a destination and, optionally, an origin and walking/driving/cycling/transit mode. Endpoint objects accept exactly one of `place_ref`, `event_ref`, or a `coordinates` object containing latitude, longitude and an optional title. With directions but no origin, Maps chooses its starting point; the plugin does not read device location. Opening an app changes focus but does not edit calendar data.

## Routes and appointment connections

`calculate_route` estimates real route distance and travel time using `MKDirections.calculateETA`. Origin and destination use the same generic endpoint objects as Maps handoff. Optional `depart_at` and `arrive_by` timestamps are mutually exclusive. Supported modes are walking, driving, cycling and transit, subject to Apple Maps coverage for the requested area and date. Missing routes fail explicitly; straight-line distance is never substituted for route duration.

`check_travel_feasibility` checks travel time plus an explicit `buffer_minutes` against an available interval, and finds other busy appointments overlapping the required journey/arrival-buffer interval. Timed origin/destination event endpoints default to the former's end and the latter's start; planned locations or all-day events need explicit `available_from` and `arrive_by` values. Optional `calendar_ids` controls which synced calendars are checked. Endpoint events are excluded from the additional conflicts. `can_arrive_on_time` reports the time calculation; `feasible` also requires no additional calendar conflicts. Explicit output time zones are honored.

These operations are read-only. They do not move appointments, reserve travel blocks, write Apple's built-in Travel Time field or enable dynamic Time to Leave alerts. A caller may create a distinct travel block with `create_event` only when the person requested reserving that time. Estimates are not guaranteed arrivals and do not prove current traffic, location or other-device state.

## Scope and limits

- Only calendars and events synced to this Mac are available. Saving locally does not prove remote-account or other-device synchronization.
- Search windows are limited to 366 days, free-time windows to 31 days, and event pages to 200 results. Pagination is explicit.
- Free-time results exclude cancelled events, declined invitations and events marked free. Tentative and unknown availability block time. No remote attendee free/busy lookup is performed.
- Attendees and organizers are read-only. Events with attendees are protected from editing and deletion because those actions can send invitations or cancellations. Use Apple Calendar for invitations, cancellations and responses.
- Subscribed and other read-only calendars cannot be edited. Calendar account administration, calendar creation/deletion and Reminders are outside this plugin's scope.
- The plugin uses standard MCP tool approval annotations. The caller should only write in response to the person's actual request.

## Build and verify

```bash
bash scripts/build.sh
python3 scripts/verify.py
python3 scripts/read_check.py
python3 scripts/route_check.py
bash scripts/run.sh --check-places 'PLACE OR BUILDING NAME' 'OPTIONAL REFERENCE ADDRESS'
# Only for an explicitly authorized live verification run:
bash scripts/run.sh --integration-test --allow-calendar-writes
```

The build script compiles Swift sources without external dependencies, stages and signs the app outside file-provider folders, and runs native self-tests. Finder metadata in a file-provider directory can prevent strict app-bundle verification in that directory; the staged app and installed cache are the appropriate signature checks.

`verify.py` exercises real MCP process startup, initialization, tool discovery, schema errors and protocol compatibility. Native tests cover date validation, daylight-saving changes, floating all-day boundaries, recurrence, partial unsaved event edits, reminders, occurrence scopes, free-time calculations, geographic validation, native location preservation and clearing, and expired place references. They do not commit events.

Also verify the package through the desktop app-server loader: `plugin/read` must report `apple-calendar` under `mcpServers`, and `mcpServerStatus/list` must discover all fifteen tools, including native handoff, route and journey checks. A successful direct stdio test alone does not prove that the plugin's launch configuration is accepted by the host.

`read_check.py` performs read-only checks of actual calendars and events and prints counts rather than event contents. Add `--authorize` only to request the native permission prompt. Verification involving AppKit must run in a normal logged-in macOS session; a restricted shell sandbox may prevent access to the WindowServer.

The live integration diagnostic creates its own uniquely named calendar under the default event source, with no attendees or explicit alerts. It verifies real native-location saves, coordinate preservation, complex recurrence expansion, entire-series changes, daylight-saving behavior, route conflicts and app handoff. It removes that exact fixture calendar on success or failure and verifies removal. It never edits existing appointments. `--inspect-ui` pauses after each handoff for manual UI inspection, requiring Return to continue; always resume both pauses to complete cleanup. `--handoff-only` restricts the run to persistence and handoff checks. Routine self-tests and protocol tests never write calendars.

Development validation previously checked local persistence and map-card presentation using an isolated iCloud fixture calendar. That does not establish remote/other-device synchronization or Exchange write persistence. Native Calendar and Maps UI inspection is a diagnostic step, not the implementation of the location or handoff tools.

`--check-places` makes a real Apple Maps query and verifies that the first returned candidate can be converted into a native location on an unsaved event. It checks coordinate conversion and preservation, not whether that candidate is the exact intended destination. It performs no live calendar writes. The optional reference argument can be omitted entirely.

## Logo

- `assets/logo.png`: static 1024-pixel cover and composer icon.
- `assets/logo.svg`: editable static vector source.

Both plugin manifests use the same static PNG. The package contains no animated logo assets.

## References

- [OpenAI: Package your plugin](https://developers.openai.com/plugins/build/plugins)
- [Apple: Accessing Calendar using EventKit](https://developer.apple.com/documentation/eventkit/accessing-calendar-using-eventkit-and-eventkitui)
- [Apple: Floating event time zones](https://developer.apple.com/documentation/eventkit/ekcalendaritem/timezone)
- [Apple: Native location from a map item](https://developer.apple.com/documentation/eventkit/ekstructuredlocation/init(mapitem:))
- [Apple: MapKit local search](https://developer.apple.com/documentation/mapkit/mklocalsearch)
- [Apple: Recurrence rules](https://developer.apple.com/documentation/eventkit/ekrecurrencerule)
- [Apple: Route estimates](https://developer.apple.com/documentation/mapkit/mkdirections/calculateeta(completionhandler:))
- [MCP specification: stdio transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)

This is an independent integration, not an Apple or OpenAI product.
