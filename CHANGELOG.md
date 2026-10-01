# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/).

## [0.4.0] - 2026-10-02

First public release.

### Added
- RRULE `BYMONTH` and `BYSETPOS` (e.g. "last weekday of the month"), also shown by `get_event`.
- `structuredContent` for `delete_event` and `import_ics`.
- Windows time zone names in `.ics` files are resolved through the system ICU (all zones).
- A denied Calendar/Reminders permission is re-requested on the next call, so granting it in
  System Settings works without a restart.

### Changed
- Writes to an ambiguous calendar or reminder list name are refused; use `Title (Account)`.
- `search_events` default range: from 30 days ago, 120 days; accepts `days`.
- `UNTIL` also accepts `YYYY-MM-DD`.
- The binary is signed with an identifier-based requirement, so permissions survive rebuilds.
- Time zone changes (travel) are picked up without a restart.

### Removed
- `complete_reminder`; use `update_reminder` with `completed`.

### Fixed
- `update_event` with only `all_day` (unchanged) no longer resets the event duration.
- Invalid `UNTIL`, `COUNT` or `INTERVAL` no longer creates an endless or broken series.
- A failed `EXDATE` removal during import is a warning, not a failed import.

## [0.3.0] - 2026-10-01

### Added
- `get_event`, `update_event`, `search_events`.
- `create_event`: `all_day`, `recurrence`, `url`, `alarms_minutes`.
- Per-occurrence operations for recurring events (`occurrence_start`, `span`).
- `ping`, protocol version negotiation, `structuredContent` for event tools.

## [0.2.0]

### Added
- `import_ics`.
- Reminders tools.

[0.4.0]: https://github.com/Puhavik/apple-calendar-mcp/releases/tag/v0.4.0
