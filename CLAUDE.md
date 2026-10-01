# apple-calendar-mcp

Stdio MCP server (JSON-RPC, one JSON per line) over EventKit: Apple Calendar + Apple Reminders.
Single file `main.swift`, Swift, no packages. User-facing docs: `README.md`; changes: `CHANGELOG.md`.
Machine-specific notes (install path, local calendars) go in `CLAUDE.local.md` (gitignored).

## Build / run
- `./build.sh` — `swiftc -O -licucore` (ICU maps Windows TZ names), embeds `Info.plist`, ad-hoc signs with
  identifier `local.apple-calendar-mcp` and designated requirement `identifier "local.apple-calendar-mcp"`
  (not cdhash), so TCC grants survive rebuilds. Keep the identifier.
- After a rebuild, restart Claude Desktop so it respawns the server.
- The binary re-execs itself with `responsibility_spawnattrs_setdisclaim` so Calendar/Reminders
  permission belongs to this binary, not to the host app. Don't remove that block.
- `store.reset()` runs before every tools/call: without a run loop the EventKit cache goes stale
  (e.g. a calendar created in Calendar.app stays invisible until restart).
- A cached Calendar/Reminders denial is re-requested on the next call (`needEvents`/`needReminders`),
  so granting access in System Settings works without a restart.

## Smoke test (read-only)
```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_events","arguments":{"days":3}}}' \
  | timeout 20 ./apple-calendar-mcp
```

## Conventions
- Dates: `YYYY-MM-DD HH:MM` local time, or `YYYY-MM-DD` (all-day / whole day). POSIX-locale formatters.
- Calendar names: exact title, `Title (Source)` for duplicates (e.g. `Work (iCloud)`), or case-insensitive.
  Several writable matches for a write → error asking for `Title (Source)`.
- Recurring events share one `eventIdentifier`; tools take `occurrence_start` to target an occurrence
  and `span: this|future`. A detached (edited) occurrence gets its own id `<series id>/RID=<n>`,
  `recurring: false`; deleting the series with span=future removes it too.
- Every tool returns a text summary; event tools also set the global `structured` → `structuredContent`.
- Errors: throw `Err("...")`, surfaced as `isError: true`.
- Bump `serverInfo.version` in `main.swift` and add a `CHANGELOG.md` entry for each release.

## Testing
- Write tests only in a scratch calendar `MCP Test`, never in real calendars. Create it with
  `osascript -e 'tell application "Calendar" to make new calendar with properties {name:"MCP Test"}'`
  and delete the test events afterwards.
- `tccutil reset Calendar <id>` does not work for this binary (not an app bundle); re-grant access in
  System Settings > Privacy & Security > Calendars.
- Last full manual pass (v0.4.0): all event, search, import_ics (incl. 6 Windows TZIDs, EXDATE,
  BYSETPOS/BYMONTH) and reminder paths. Not covered: access re-request after a real denial,
  time-zone change while the server runs, EXDATE removal failure, read-only reminder lists.
