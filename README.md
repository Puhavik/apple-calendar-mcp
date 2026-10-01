# apple-calendar-mcp

A [Model Context Protocol](https://modelcontextprotocol.io) server that gives AI assistants such as
Claude Desktop native access to **Apple Calendar** and **Apple Reminders** on macOS.

It talks to EventKit directly — no AppleScript, no Calendar.app automation, no network, no
dependencies. One Swift file, one small binary.

## Features

- Every account Calendar.app knows: iCloud, Google, Exchange, CalDAV, local, subscribed.
- Full event support: all-day and timed events, locations, notes, URLs, alerts, recurrence (RRULE),
  editing or deleting a single occurrence or "this and all future" ones, moving events between calendars.
- Search by title, location or notes (case- and accent-insensitive).
- `.ics` import without any dialog: time zones including Outlook/Teams Windows names, all-day events,
  recurrence with `EXDATE`, alarms, organizer, Teams/Zoom/Meet join links, duplicate detection, dry run.
- Reminders: lists, due dates with alerts, priority, completion, moving between lists.
- Machine-readable `structuredContent` alongside text for event tools.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode Command Line Tools (`xcode-select --install`) to build

## Installation

```sh
git clone https://github.com/Puhavik/apple-calendar-mcp.git
cd apple-calendar-mcp
./build.sh
```

`build.sh` compiles `main.swift`, embeds `Info.plist` (the Calendar/Reminders usage descriptions) and
ad-hoc signs the binary.

### Claude Desktop

Add the server to `~/Library/Application Support/Claude/claude_desktop_config.json`, using the
absolute path of the binary you just built:

```json
{
  "mcpServers": {
    "apple-calendar": {
      "command": "/absolute/path/to/apple-calendar-mcp/apple-calendar-mcp"
    }
  }
}
```

Restart Claude Desktop. On first use macOS asks for Calendar and Reminders access for
`apple-calendar-mcp`; choose **Allow Full Access**.

Any other MCP client that launches stdio servers works the same way: run the binary, speak JSON-RPC
over stdin/stdout.

## Permissions

The server re-launches itself so macOS attributes the Calendar/Reminders permission to
`apple-calendar-mcp` itself, not to the app that started it. Access is managed in
**System Settings → Privacy & Security → Calendars / Reminders**. If you deny access and enable it
later, the next tool call picks it up — no restart needed.

## Tools

| Tool | What it does |
| --- | --- |
| `list_calendars` | Calendars with account, read-only and default flags |
| `list_events` | Events in a range (default: today + 7 days); recurring events expanded into occurrences |
| `search_events` | Find events by text in title, location or notes (default: 30 days back, 120 days span) |
| `get_event` | Full details: notes, URL, RRULE, alerts, organizer, attendees |
| `create_event` | New event; `all_day`, `recurrence`, `alarms_minutes`, `url`, `location`, `notes` |
| `update_event` | Change any field, one occurrence or `span: future`, move to another calendar |
| `delete_event` | Delete an event, one occurrence, or this and future occurrences |
| `import_ics` | Import an `.ics` file or text; `dry_run`, `skip_duplicates`, `alarms_minutes` override |
| `list_reminder_lists` | Reminder lists |
| `list_reminders` | Reminders, incomplete by default; filter by list or due window |
| `create_reminder` | New reminder with optional due date, alert, priority, list |
| `update_reminder` | Change any field, mark completed, move to another list |
| `delete_reminder` | Delete a reminder |

### Conventions

- **Dates** are local time: `YYYY-MM-DD HH:MM`, or `YYYY-MM-DD` for all-day events and whole days.
- **Calendar and list names** match exactly, case-insensitively, or as `Title (Account)` when two
  calendars share a title, e.g. `Work (iCloud)`. A write to an ambiguous name is refused.
- **Recurring events**: `list_events` shows an `occurrence_start` for each occurrence. Pass it to
  `get_event`, `update_event` or `delete_event` to target that occurrence; add `span: "future"` to
  include all later ones.
- **Recurrence** takes an RRULE: `FREQ`, `INTERVAL`, `COUNT`, `UNTIL`, `BYDAY`, `BYMONTHDAY`,
  `BYMONTH`, `BYSETPOS`. Example: last weekday of every month —
  `FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1`.

## Quick check

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_events","arguments":{"days":3}}}' \
  | ./apple-calendar-mcp
```

## Limitations

- macOS only (EventKit).
- `.ics` import skips cancelled events and single overridden instances (`RECURRENCE-ID`) of a series.
- Attendees and organizer are read-only (EventKit does not allow sending invitations).

## License

[GPL-3.0-or-later](LICENSE) © 2026 Vikentiy Pukhaev
