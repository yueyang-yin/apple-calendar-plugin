# Apple Calendar plugin

A local macOS plugin for Codex that reads and manages events through Apple's EventKit framework. It works with calendars synced to Apple Calendar, including iCloud, Exchange, CalDAV, and local calendars.

The plugin provides 15 MCP tools for calendar search, event creation and editing, recurring schedules, free-time lookup, native map locations, route estimates, and opening events in Calendar or Maps. See the [plugin guide](plugins/apple-calendar/README.md) for the full behavior, permissions, and limits.

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
