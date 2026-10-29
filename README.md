# Apple Calendar plugin

A local macOS plugin for Codex that reads and manages events through Apple's EventKit framework. It works with calendars synced to Apple Calendar, including iCloud, Exchange, CalDAV, and local calendars.

The plugin provides 15 MCP tools for calendar search, event creation and editing, recurring schedules, free-time lookup, native map locations, route estimates, and opening events in Calendar or Maps. See the [plugin guide](plugins/apple-calendar/README.md) for the full behavior, permissions, and limits.

## Compared with OpenAI's iCloud Calendar plugin

OpenAI also publishes **iCloud Calendar** (`icloud-calendar`) in the [official plugin directory](https://chatgpt.com/plugins). This repository is an independent **Apple Calendar** integration. The main difference is the calendar source: the official plugin accesses Apple-hosted iCloud calendars through a connected iCloud account; this plugin accesses the calendars synced to a particular Mac through EventKit. An Exchange calendar appearing in Apple's Calendar app is still an Exchange calendar, so it is outside the official iCloud plugin's scope.

The comparison below was checked on **October 29, 2026**, against the OpenAI-authored iCloud Calendar **1.0.3** manifest and the official tool descriptions and input schemas available in this session, and this repository's **1.2.0** source. Official features and availability can change. An absent tool or input is described as absent from the inspected interface, rather than a claim about all underlying iCloud capabilities. No live event writes, invitations, attachment operations, or cross-device tests were performed for this comparison.

| Area | This Apple Calendar plugin | OpenAI's iCloud Calendar plugin |
| --- | --- | --- |
| Calendar coverage | iCloud, Exchange, CalDAV, and local calendars visible to EventKit on the Mac; provider permissions and sync apply. | Apple-hosted calendars available to the connected iCloud account; does not expose the Mac's Exchange, other CalDAV, or local calendars. |
| Runtime and setup | A local Swift MCP process on macOS 14+, requiring native full calendar access. The bundled executable targets Apple Silicon. No separate iCloud login is supplied to this plugin. | An official account-connected integration. Its package declares the iCloud connector rather than a local EventKit executable. Client and account availability depend on OpenAI; this comparison does not establish support on every platform. |
| Everyday events | Search, read, create, update, and delete personal events, with all-day dates, time zones, reminders, and recurrence. | Search, read, create, update, and delete events, with all-day dates, time zones, alerts, and recurrence. |
| Recurring schedules | Daily, weekly, monthly, and yearly rules; single, future, and entire-series changes. Also exposes ordinal weekdays, week-of-year and day-of-year filters, subject to EventKit validation. | Daily, weekly, monthly, and yearly rules, including weekday, month-day, month, and position filters; single-instance, following-instance, and entire-series changes. No separate week-of-year or day-of-year input is exposed. |
| Meetings and invitations | Attendees are read-only. Creating invitations, replying to invitations, and editing or deleting events with attendees are blocked. | Supports inviting guests, adding/removing attendees, updating/canceling meetings you organize, and accepting, tentatively accepting, or declining invitations. Meeting operations may notify people. |
| Contacts | No contact tools. | Search and read iCloud contacts; no contact-write tool is exposed. |
| Event attachments | No attachment tools. | Download event attachments. Add/replace/remove files on one-time events without attendees; removal requires a managed attachment. External attachment links cannot be downloaded through the attachment tool. |
| Native locations | Search Apple Maps, save a native place or verified coordinate pin, preserve it on unrelated edits, and verify coordinates after saving. | Event create/update inputs expose a text `location`; no place-search or structured-coordinate input is exposed. This does not establish how Apple clients render that text. |
| Routes and travel checks | Apple Maps route estimates and checks of journey time, arrival buffer, and conflicts between appointments. | No dedicated route-estimation or travel-feasibility tool is exposed. |
| Finding free time | Dedicated `find_free_time` across selected synced calendars, up to 31 days; no remote attendee availability lookup. | No dedicated free-time tool is exposed. Event search can supply schedule data for caller-side reasoning. |
| Mac application handoff | Open an exact event in Calendar or a destination/directions in Maps. Calendar handoff needs Automation permission. | No native Calendar/Maps handoff tool is exposed. |
| Search limits | Up to 366 days per event search, 200 results per page, with `has_more` / `next_offset` pagination. | Up to 93 days per event search and 100 occurrences per response. No page cursor; when `has_more` is true, narrow the dates or selected calendars and search again. |
| Change checks and sync | Create/update saves are read back from EventKit; native coordinates are checked when present. This verifies local persistence, not remote-account or other-device sync. | Updates, deletions, invitation responses, and attachment mutations require the latest event `etag` as `expected_etag`. Uncertain results require a read before retrying. This interface check does not establish other-device sync behavior. |

Choose the official plugin for iCloud-focused work that needs meeting invitations, invitation responses, contacts, or attachments. Choose this plugin for calendars from multiple accounts already synced to a Mac, native map locations, route planning, local free-time lookup, or opening events in Mac apps. The official plugin's broader collaboration support and this plugin's broader local account coverage serve different needs.

Both can access the same iCloud calendar when it is connected to the official plugin and synced to the Mac. They are alternative access paths to that calendar; installing both does not migrate or duplicate it. Specify the intended plugin/account when both are available, and retrieve IDs through that plugin rather than exchanging `event_id` and `event_ref` values.

Sources: find **iCloud Calendar** by **OpenAI** in the [plugin directory](https://chatgpt.com/plugins); its inspected tools include `search_events`, `create_event`, `update_event`, `respond_event`, `search_contacts`, and the `*_event_attachment` tools. OpenAI's [plugin documentation](https://learn.chatgpt.com/docs/plugins) explains installation and surface availability. This plugin's [tool schemas](plugins/apple-calendar/server/Sources/Tools.swift), [calendar implementation](plugins/apple-calendar/server/Sources/CalendarService.swift), and [recurrence validation](plugins/apple-calendar/server/Sources/Recurrence.swift) define the local behavior above.

## Requirements

- A Mac running macOS 14 or later and a local Codex desktop session.
- Apple Silicon for the bundled executable. Intel users must rebuild it locally with Xcode Command Line Tools before installing.
- Calendar accounts configured in Apple Calendar and full calendar access granted when requested.
- Internet access for Apple Maps searches and routes. Opening events in Calendar also needs macOS Automation permission.

The executable is ad hoc signed, not Developer ID signed or notarized. If macOS blocks a downloaded copy, review the source and rebuild it locally with `bash plugins/apple-calendar/scripts/build.sh` before installing. Do not disable Gatekeeper globally.

## Install from GitHub

Register this repository as a marketplace:

```bash
codex plugin marketplace add https://github.com/yueyang-yin/apple-calendar-plugin.git --ref main
```

In the desktop app's Plugins directory, select **Apple Calendar Local**, open **Apple Calendar**, and install it. Start a new local chat if the tools have not refreshed. On CLI versions supporting plugin installation, you can also run:

```bash
codex plugin add apple-calendar@apple-calendar-local
```

If your app offers an **Add marketplace** action, use this repository URL there. UI availability varies by client version; the CLI command above registers the same marketplace source.

## Install from a ZIP

Download the assets from [Releases](https://github.com/yueyang-yin/apple-calendar-plugin/releases/latest).

| Asset | Use |
| --- | --- |
| `Apple-Calendar-Marketplace-1.2.0.zip` | Recommended for local installation. Extract it, register the extracted marketplace, then install the plugin. |
| `Apple-Calendar-1.2.0.zip` | A standalone plugin bundle with one `apple-calendar/` root, for clients that support plugin ZIP import. |
| `SHA256SUMS.txt` | SHA-256 checksums for both archives. |

For the marketplace ZIP, extract it to a permanent local directory and run:

```bash
codex plugin marketplace add /absolute/path/to/apple-calendar-marketplace
codex plugin add apple-calendar@apple-calendar-local
```

You can also install through the desktop Plugins directory after registering the marketplace. A plugin ZIP and a marketplace ZIP serve different import flows: if your app only supports adding a marketplace, use the marketplace ZIP or GitHub instructions. A GitHub release does not publish the plugin to OpenAI's public directory.

## First use

Ask the plugin to check `calendar_status`. If access is missing, use `request_access` and answer the native permission prompt. Then use `list_calendars` to choose the account and calendar you intend to use.

Example requests:

- Show today's appointments from my Exchange calendar.
- Find a free hour next week in the calendars I select.
- Create an appointment at a place I choose and verify its saved map location.

Writes require your actual scheduling request. The plugin does not send invitations, respond to invitations, or edit events with attendees.

## macOS and iOS

This package runs a local Swift MCP process on the Mac. It accesses the calendars synced to that Mac; it does not install an iPhone extension or run directly in the ChatGPT iOS app. Installing a local marketplace plugin does not make its executable available on the web or phone.

Where your account supports mobile remote connections, you can connect the phone to an awake, online Mac and work through that host. The MCP process and calendar permissions still belong to the Mac. This package's mobile remote workflow has not been tested.

See OpenAI's [plugin availability](https://learn.chatgpt.com/docs/plugins), [local marketplace setup](https://developers.openai.com/plugins/build/plugins), and [remote connections](https://learn.chatgpt.com/docs/remote-connections) documentation. Public-directory submission and review are separate from distributing this repository.

## Privacy

Calendar data travels from EventKit to the local MCP client. The host may include tool results in the conversation according to its own data settings. Optional map queries send search text and reference addresses or coordinates to Apple Maps. No API key, OAuth credential, hosted server, or third-party package is required to run the plugin. No calendar database or user account configuration is bundled in this repository.

## Build and verify

```bash
bash plugins/apple-calendar/scripts/build.sh
python3 plugins/apple-calendar/scripts/verify.py
python3 scripts/package.py
```

The build script compiles the Swift source, ad hoc signs the native app, and runs native self-tests. Protocol tests exercise actual process startup and tool discovery without committing calendar events. Packaging writes both ZIPs and their checksums to `dist/`, which is excluded from Git.

The source, compatibility manifest, and portable manifest live in `plugins/apple-calendar/`. The repository marketplace is `.agents/plugins/marketplace.json`. The included app binary targets Apple Silicon and macOS 14; this does not establish testing on every macOS version or Intel hardware.

See [version 1.2.0 release notes](docs/releases/1.2.0.md) for the distribution contents. This is an independent integration, not an Apple or OpenAI product.

## License

This project is licensed under the [MIT License](LICENSE).
