// apple-calendar-mcp: MCP (stdio JSON-RPC) server over EventKit for Apple Calendar and Apple Reminders.
// Copyright (C) 2026 Vikentiy Pukhaev
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import EventKit

// Claude.app spawns tools via a "disclaimer" helper, so macOS would ask Claude's versioned
// CLI bundle for Calendar access. Re-exec disclaiming responsibility so the permission
// belongs to this binary and survives Claude updates.
@_silgen_name("responsibility_spawnattrs_setdisclaim")
func responsibility_spawnattrs_setdisclaim(_ attrs: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32) -> Int32

if ProcessInfo.processInfo.environment["APPLE_CAL_MCP_CHILD"] == nil {
    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    _ = responsibility_spawnattrs_setdisclaim(&attr, 1)
    setenv("APPLE_CAL_MCP_CHILD", "1", 1)
    let path = CommandLine.arguments[0]
    var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) } + [nil]
    var pid: pid_t = 0
    if posix_spawn(&pid, path, nil, &attr, &argv, environ) == 0 {
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let sig = status & 0x7f
        exit(sig != 0 ? 128 + sig : (status >> 8) & 0xff)
    }
    // spawn failed: fall through and run in-process
}

let store = EKEventStore()

func requestAccess(_ type: EKEntityType) -> String? {
    var err: String? = nil
    let sem = DispatchSemaphore(value: 0)
    let what = type == .event ? "Calendars" : "Reminders"
    let done: (Bool, Error?) -> Void = { ok, e in
        if !ok { err = e?.localizedDescription ?? "\(what.lowercased()) access denied (System Settings > Privacy & Security > \(what))" }
        sem.signal()
    }
    if type == .event { store.requestFullAccessToEvents(completion: done) }
    else { store.requestFullAccessToReminders(completion: done) }
    sem.wait()
    return err
}

var eventsAccessError: String? = nil
var remindersAccessError: String? = nil

// POSIX formatter; local ones follow the system time zone (reset per tools/call, see main loop).
func posixFmt(_ format: String, _ tz: TimeZone = .autoupdatingCurrent) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = tz
    f.dateFormat = format
    return f
}
let iso = posixFmt("yyyy-MM-dd HH:mm")
let dayFmt = posixFmt("yyyy-MM-dd")
let icsDayFmt = posixFmt("yyyyMMdd")
let icsUTCFmt = posixFmt("yyyyMMdd'T'HHmmss'Z'", TimeZone(identifier: "UTC")!)
let icsLocalFmt = posixFmt("yyyyMMdd'T'HHmmss")

// Optional machine-readable payload for the current tools/call (sent as structuredContent).
var structured: [String: Any]? = nil

func ints(_ v: Any?) -> [Int]? {
    (v as? [Any])?.compactMap { ($0 as? Int) ?? ($0 as? Double).map { Int($0) } }
}
func isDateOnly(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).count <= 10 }

struct Err: LocalizedError { let m: String; init(_ m: String) { self.m = m }
    var errorDescription: String? { m } }

func parseDate(_ raw: String) throws -> Date {
    let s = raw.trimmingCharacters(in: .whitespaces)
    if let d = iso.date(from: s) { return d }
    if let d = dayFmt.date(from: s) { return d }
    throw Err("bad date \(s) — want 'YYYY-MM-DD HH:MM'")
}

// On a cached denial ask again, so access granted in System Settings works without a restart.
func needEvents() throws {
    if eventsAccessError != nil { eventsAccessError = requestAccess(.event); if eventsAccessError == nil { store.reset() } }
    if let e = eventsAccessError { throw Err("calendar access: \(e)") }
}
func needReminders() throws {
    if remindersAccessError != nil { remindersAccessError = requestAccess(.reminder); if remindersAccessError == nil { store.reset() } }
    if let e = remindersAccessError { throw Err("reminders access: \(e)") }
}

// MARK: - Calendar

func calLabel(_ c: EKCalendar) -> String { "\(c.title) (\(c.source?.title ?? "?"))" }

/// Resolve a calendar name for events or reminders. Accepts "Title", "Title (Source)" or a
/// case-insensitive title. nil -> all calendars of that type.
func resolveCalendars(_ name: String?, _ type: EKEntityType) throws -> [EKCalendar] {
    let all = store.calendars(for: type)
    guard let name, !name.isEmpty else { return all }
    var hit = all.filter { $0.title == name }
    if hit.isEmpty { hit = all.filter { calLabel($0) == name } }
    if hit.isEmpty { hit = all.filter { $0.title.caseInsensitiveCompare(name) == .orderedSame } }
    if hit.isEmpty {
        let what = type == .event ? "calendar" : "reminder list"
        throw Err("no \(what) named '\(name)'. Have: " + all.map(calLabel).joined(separator: ", "))
    }
    return hit
}

func calendars(named name: String?) throws -> [EKCalendar] {
    try needEvents()
    return try resolveCalendars(name, .event)
}

/// Target calendar (or reminder list) for writes: the named writable one or the system default.
/// Several writable matches -> error, caller must use 'Title (Source)'.
func writableCalendar(_ name: String?, _ type: EKEntityType = .event) throws -> EKCalendar {
    if type == .event { try needEvents() } else { try needReminders() }
    let (what, arg) = type == .event ? ("calendar", "calendar") : ("reminder list", "list")
    guard let name, !name.isEmpty else {
        let d = type == .event ? store.defaultCalendarForNewEvents : store.defaultCalendarForNewReminders()
        guard let d else { throw Err("no default \(what); pass '\(arg)'") }
        return d
    }
    let w = try resolveCalendars(name, type).filter { $0.allowsContentModifications }
    guard let c = w.first else { throw Err("\(what) '\(name)' is read-only") }
    if w.count > 1 { throw Err("\(what) '\(name)' is ambiguous, use one of: " + w.map(calLabel).joined(separator: ", ")) }
    return c
}

func listCalendars() throws -> String {
    try needEvents()
    let def = store.defaultCalendarForNewEvents?.calendarIdentifier
    let cals = store.calendars(for: .event)
    structured = ["calendars": cals.map { c -> [String: Any] in
        ["title": c.title, "source": c.source?.title ?? "", "writable": c.allowsContentModifications,
         "default": c.calendarIdentifier == def, "id": c.calendarIdentifier] }]
    let dupTitles = Set(Dictionary(grouping: cals, by: \.title).filter { $0.value.count > 1 }.keys)
    return cals.map { c in
        (dupTitles.contains(c.title) ? calLabel(c) : c.title) + " | " + (c.source?.title ?? "?")
            + (c.allowsContentModifications ? "" : " | read-only")
            + (c.calendarIdentifier == def ? " | default" : "")
    }.joined(separator: "\n")
}

func fmtDate(_ d: Date, allDay: Bool) -> String { allDay ? dayFmt.string(from: d) : iso.string(from: d) }

let weekdayCodes: [EKWeekday: String] = [.sunday: "SU", .monday: "MO", .tuesday: "TU", .wednesday: "WE",
                                         .thursday: "TH", .friday: "FR", .saturday: "SA"]

func rruleString(_ r: EKRecurrenceRule) -> String {
    let f: String
    switch r.frequency { case .daily: f = "DAILY"; case .weekly: f = "WEEKLY"; case .monthly: f = "MONTHLY"; case .yearly: f = "YEARLY"; @unknown default: f = "?" }
    var parts = ["FREQ=\(f)"]
    if r.interval > 1 { parts.append("INTERVAL=\(r.interval)") }
    if let days = r.daysOfTheWeek, !days.isEmpty {
        parts.append("BYDAY=" + days.map { ($0.weekNumber != 0 ? "\($0.weekNumber)" : "") + (weekdayCodes[$0.dayOfTheWeek] ?? "") }.joined(separator: ","))
    }
    for (k, v) in [("BYMONTHDAY", r.daysOfTheMonth), ("BYMONTH", r.monthsOfTheYear), ("BYSETPOS", r.setPositions)] {
        if let v, !v.isEmpty { parts.append("\(k)=" + v.map { "\($0)" }.joined(separator: ",")) }
    }
    if let end = r.recurrenceEnd {
        if end.occurrenceCount > 0 { parts.append("COUNT=\(end.occurrenceCount)") }
        else if let d = end.endDate { parts.append("UNTIL=" + dayFmt.string(from: d).replacingOccurrences(of: "-", with: "")) }
    }
    return parts.joined(separator: ";")
}

func statusName(_ s: EKParticipantStatus) -> String {
    switch s {
    case .accepted: return "accepted"; case .declined: return "declined"; case .tentative: return "tentative"
    case .pending: return "pending"; case .delegated: return "delegated"; default: return "unknown"
    }
}

func eventDict(_ e: EKEvent, full: Bool) -> [String: Any] {
    var d: [String: Any] = [
        "id": e.eventIdentifier ?? "", "calendar": e.calendar.title, "title": e.title ?? "",
        "start": fmtDate(e.startDate, allDay: e.isAllDay), "end": fmtDate(e.endDate, allDay: e.isAllDay),
        "all_day": e.isAllDay, "recurring": e.hasRecurrenceRules,
    ]
    if e.hasRecurrenceRules { d["occurrence_start"] = iso.string(from: e.startDate) }
    if let l = e.location, !l.isEmpty { d["location"] = l }
    guard full else { return d }
    d["calendar_source"] = e.calendar.source?.title ?? ""
    d["writable"] = e.calendar.allowsContentModifications
    if let n = e.notes, !n.isEmpty { d["notes"] = n }
    if let u = e.url { d["url"] = u.absoluteString }
    if let r = e.recurrenceRules?.first { d["recurrence"] = rruleString(r) }
    if e.isDetached { d["detached"] = true }
    let alarms = (e.alarms ?? []).compactMap { a -> Int? in a.absoluteDate == nil ? Int(-a.relativeOffset / 60) : nil }
    if !alarms.isEmpty { d["alarms_minutes"] = alarms }
    if let o = e.organizer { d["organizer"] = o.name ?? o.url.absoluteString }
    if let at = e.attendees, !at.isEmpty {
        d["attendees"] = at.map { p -> String in
            "\(p.name ?? p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")) (\(statusName(p.participantStatus)))" }
    }
    if let x = e.calendarItemExternalIdentifier { d["external_id"] = x }
    return d
}

func eventLine(_ e: EKEvent) -> String {
    "\(e.calendar.title) | \(e.title ?? "") | \(fmtDate(e.startDate, allDay: e.isAllDay)) - \(fmtDate(e.endDate, allDay: e.isAllDay))"
        + (e.isAllDay ? " (all day)" : "") + (e.location?.isEmpty == false ? " | @\(e.location!)" : "")
        + (e.hasRecurrenceRules ? " | recurring, occurrence_start=\(iso.string(from: e.startDate))" : "")
        + " | id=\(e.eventIdentifier ?? "")"
}

/// Date range from 'from'/'to' (or 'days'). Date-only 'to' is inclusive (end of that day).
func dateRange(_ a: [String: Any], defaultFrom: Date, defaultDays: Int) throws -> (Date, Date) {
    let cal = Calendar.current
    let from = try (a["from"] as? String).map(parseDate) ?? defaultFrom
    var to: Date
    if let t = a["to"] as? String {
        to = try parseDate(t)
        if isDateOnly(t) { to = cal.date(byAdding: .day, value: 1, to: to)! }
    } else {
        to = cal.date(byAdding: .day, value: max(a["days"] as? Int ?? defaultDays, 1), to: cal.startOfDay(for: from))!
    }
    guard to > from else { throw Err("'to' must be after 'from'") }
    return (from, to)
}

func fetchEvents(_ from: Date, _ to: Date, _ cals: [EKCalendar]) -> [EKEvent] {
    // EventKit caps a predicate at ~4 years; chunk by year to be safe.
    var out: [EKEvent] = []; var s = from
    while s < to {
        let e = min(Calendar.current.date(byAdding: .year, value: 1, to: s)!, to)
        out += store.events(matching: store.predicateForEvents(withStart: s, end: e, calendars: cals))
        s = e
    }
    var seen = Set<String>()
    return out.filter { seen.insert(($0.eventIdentifier ?? "") + "@\($0.startDate.timeIntervalSince1970)").inserted }
        .sorted { $0.startDate < $1.startDate }
}

func listEvents(_ a: [String: Any]) throws -> String {
    let cals = try calendars(named: a["calendar"] as? String)
    let (from, to) = try dateRange(a, defaultFrom: Calendar.current.startOfDay(for: Date()), defaultDays: 7)
    let evs = fetchEvents(from, to, cals)
    structured = ["from": iso.string(from: from), "to": iso.string(from: to), "events": evs.map { eventDict($0, full: false) }]
    return evs.isEmpty ? "no events" : evs.map(eventLine).joined(separator: "\n")
}

func searchEvents(_ a: [String: Any]) throws -> String {
    guard let q = (a["query"] as? String)?.trimmingCharacters(in: .whitespaces), !q.isEmpty else { throw Err("query required") }
    let cals = try calendars(named: a["calendar"] as? String)
    let today = Calendar.current.startOfDay(for: Date())
    let (from, to) = try dateRange(a, defaultFrom: Calendar.current.date(byAdding: .day, value: -30, to: today)!, defaultDays: 120)
    let limit = max(a["limit"] as? Int ?? 50, 1)
    let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    let hits = fetchEvents(from, to, cals).filter { e in
        [e.title, e.location, e.notes].contains { $0?.range(of: q, options: opts) != nil }
    }
    let shown = Array(hits.prefix(limit))
    structured = ["query": q, "from": iso.string(from: from), "to": iso.string(from: to), "total": hits.count,
                  "events": shown.map { eventDict($0, full: false) }]
    if shown.isEmpty { return "no events matching '\(q)' between \(dayFmt.string(from: from)) and \(dayFmt.string(from: to))" }
    return shown.map(eventLine).joined(separator: "\n") + (hits.count > limit ? "\n… \(hits.count - limit) more (raise 'limit')" : "")
}

/// The event for an id. For recurring events, 'occurrence_start' ('YYYY-MM-DD HH:MM' as shown by
/// list_events) selects that specific occurrence; otherwise the first/next occurrence is used.
func findEvent(_ a: [String: Any]) throws -> EKEvent {
    try needEvents()
    guard let id = a["id"] as? String, let base = store.event(withIdentifier: id) else { throw Err("event id not found") }
    guard let occS = a["occurrence_start"] as? String, !occS.isEmpty else { return base }
    let occ = try parseDate(occS)
    let dateOnly = isDateOnly(occS)
    let window: TimeInterval = dateOnly ? 86400 : 60
    let pred = store.predicateForEvents(withStart: occ.addingTimeInterval(-window), end: occ.addingTimeInterval(window * 2),
                                        calendars: [base.calendar])
    var matches = store.events(matching: pred).filter { $0.eventIdentifier == id }
    if dateOnly {  // whole day: only occurrences starting that day; nearest to midnight = earliest
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: occ)!
        matches = matches.filter { $0.startDate >= occ && $0.startDate < dayEnd }
    }
    guard let hit = matches.min(by: { abs($0.startDate.timeIntervalSince(occ)) < abs($1.startDate.timeIntervalSince(occ)) })
    else { throw Err("no occurrence of this event at \(occS)") }
    return hit
}

func getEvent(_ a: [String: Any]) throws -> String {
    let e = try findEvent(a)
    let d = eventDict(e, full: true)
    structured = ["event": d]
    let order = ["title", "calendar", "calendar_source", "start", "end", "all_day", "location", "url", "recurring",
                 "occurrence_start", "recurrence", "detached", "alarms_minutes", "organizer", "attendees", "notes",
                 "writable", "id", "external_id"]
    return order.compactMap { k in d[k].map { v in
        let s = (v as? [Any]).map { $0.map { "\($0)" }.joined(separator: ", ") } ?? "\(v)"
        return "\(k): \(s)" } }.joined(separator: "\n")
}

func spanArg(_ a: [String: Any]) -> EKSpan { (a["span"] as? String) == "future" ? .futureEvents : .thisEvent }

func applyAlarms(_ e: EKEvent, _ mins: [Int]) {
    for al in e.alarms ?? [] { e.removeAlarm(al) }
    for m in mins where m >= 0 { e.addAlarm(EKAlarm(relativeOffset: -Double(m) * 60)) }
}

func applyRecurrence(_ e: EKEvent, _ r: String) throws {
    for old in e.recurrenceRules ?? [] { e.removeRecurrenceRule(old) }
    let v = r.trimmingCharacters(in: .whitespaces)
    if v.isEmpty || v.lowercased() == "none" { return }
    var warnings: [String] = []
    guard let rule = recurrenceRule(v.replacingOccurrences(of: "RRULE:", with: ""), warnings: &warnings)
    else { throw Err(warnings.first ?? "bad recurrence '\(r)'") }
    if !warnings.isEmpty { throw Err(warnings.joined(separator: "; ")) }
    e.addRecurrenceRule(rule)
}

/// all-day: end is the last day (inclusive); EventKit wants the end on that same day.
func setTimes(_ e: EKEvent, start: Date, end: Date?, allDay: Bool) throws {
    e.isAllDay = allDay
    e.startDate = start
    e.endDate = end ?? (allDay ? start : start.addingTimeInterval(3600))
    if e.endDate < e.startDate { throw Err("end is before start") }
}

func createEvent(_ a: [String: Any]) throws -> String {
    guard let title = a["summary"] as? String, let startS = a["start"] as? String
    else { throw Err("summary and start required") }
    let e = EKEvent(eventStore: store)
    e.calendar = try writableCalendar(a["calendar"] as? String)
    e.title = title
    let allDay = a["all_day"] as? Bool ?? false
    try setTimes(e, start: try parseDate(startS), end: try (a["end"] as? String).map(parseDate), allDay: allDay)
    e.location = a["location"] as? String
    e.notes = a["notes"] as? String
    if let u = a["url"] as? String, !u.isEmpty { e.url = URL(string: u) }
    if let al = ints(a["alarms_minutes"]) { applyAlarms(e, al) }
    if let r = a["recurrence"] as? String { try applyRecurrence(e, r) }
    try store.save(e, span: .futureEvents)
    structured = ["event": eventDict(e, full: true)]
    return "created in \(e.calendar.title): " + eventLine(e)
}

func updateEvent(_ a: [String: Any]) throws -> String {
    let e = try findEvent(a)
    guard e.calendar.allowsContentModifications else { throw Err("calendar '\(e.calendar.title)' is read-only") }
    var span = spanArg(a)
    if let t = a["summary"] as? String { e.title = t }
    if let v = a["location"] as? String { e.location = v.isEmpty ? nil : v }
    if let v = a["notes"] as? String { e.notes = v.isEmpty ? nil : v }
    if let v = a["url"] as? String { e.url = v.isEmpty ? nil : URL(string: v) }
    let allDay = a["all_day"] as? Bool ?? e.isAllDay
    if a["start"] != nil || a["end"] != nil || a["all_day"] != nil {
        let dur = e.endDate.timeIntervalSince(e.startDate)
        let start = try (a["start"] as? String).map(parseDate) ?? e.startDate!
        var end = try (a["end"] as? String).map(parseDate)
        if end == nil && allDay == e.isAllDay { end = start.addingTimeInterval(dur) }
        try setTimes(e, start: start, end: end, allDay: allDay)
    }
    if let al = ints(a["alarms_minutes"]) { applyAlarms(e, al) }
    if let r = a["recurrence"] as? String { try applyRecurrence(e, r); span = .futureEvents }
    if let name = a["calendar"] as? String, !name.isEmpty {
        let c = try writableCalendar(name)
        if c.calendarIdentifier != e.calendar.calendarIdentifier { e.calendar = c; span = .futureEvents }
    }
    try store.save(e, span: span)
    structured = ["event": eventDict(e, full: true)]
    return "updated\(e.hasRecurrenceRules ? (span == .futureEvents ? " (this and future occurrences)" : " (this occurrence)") : ""): " + eventLine(e)
}

func deleteEvent(_ a: [String: Any]) throws -> String {
    let e = try findEvent(a)
    guard e.calendar.allowsContentModifications else { throw Err("calendar '\(e.calendar.title)' is read-only") }
    let span = spanArg(a)
    let line = eventLine(e)
    let d = eventDict(e, full: false)
    try store.remove(e, span: span)
    structured = ["deleted": d, "span": span == .futureEvents ? "future" : "this"]
    return "deleted\(span == .futureEvents ? " (this and future occurrences)" : ""): " + line
}

// MARK: - ICS import

struct ICSProp { let name: String; let params: [String: String]; let value: String }
struct VEvent { var props: [ICSProp] = []; var alarms: [TimeInterval] = [] }

func unfold(_ text: String) -> [String] {
    let norm = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    var lines: [String] = []
    for l in norm.split(separator: "\n", omittingEmptySubsequences: false) {
        if let f = l.first, f == " " || f == "\t", !lines.isEmpty { lines[lines.count - 1] += String(l.dropFirst()) }
        else { lines.append(String(l)) }
    }
    return lines
}

func unescapeICS(_ s: String) -> String {
    var out = ""; var esc = false
    for c in s {
        if esc {
            switch c { case "n", "N": out.append("\n"); default: out.append(c) }
            esc = false
        } else if c == "\\" { esc = true } else { out.append(c) }
    }
    return out
}

func parseProp(_ line: String) -> ICSProp? {
    var inQ = false; var colon: String.Index? = nil
    for i in line.indices {
        let c = line[i]
        if c == "\"" { inQ.toggle() } else if c == ":" && !inQ { colon = i; break }
    }
    guard let colon else { return nil }
    let head = String(line[..<colon]), value = String(line[line.index(after: colon)...])
    let parts = head.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
    guard let name = parts.first, !name.isEmpty else { return nil }
    var params: [String: String] = [:]
    for p in parts.dropFirst() {
        if let eq = p.firstIndex(of: "=") {
            params[String(p[..<eq]).uppercased()] = String(p[p.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }
    return ICSProp(name: name.uppercased(), params: params, value: value)
}

func parseEvents(_ text: String) -> [VEvent] {
    var events: [VEvent] = []; var cur: VEvent? = nil; var stack: [String] = []
    for line in unfold(text) {
        let up = line.uppercased()
        if up.hasPrefix("BEGIN:") {
            let n = String(up.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            stack.append(n); if n == "VEVENT" { cur = VEvent() }
            continue
        }
        if up.hasPrefix("END:") {
            let n = String(up.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            if n == "VEVENT", let c = cur { events.append(c); cur = nil }
            if !stack.isEmpty { stack.removeLast() }
            continue
        }
        guard let p = parseProp(line) else { continue }
        if stack.last == "VEVENT" { cur?.props.append(p) }
        else if stack.last == "VALARM", stack.contains("VEVENT"), p.name == "TRIGGER",
                p.params["RELATED"] != "END", p.params["VALUE"] != "DATE-TIME", let t = parseDuration(p.value) {
            cur?.alarms.append(t)
        }
    }
    return events
}

func parseDuration(_ v: String) -> TimeInterval? {
    var s = v; var sign = 1.0
    if s.hasPrefix("-") { sign = -1; s.removeFirst() } else if s.hasPrefix("+") { s.removeFirst() }
    guard s.hasPrefix("P") else { return nil }
    s.removeFirst()
    var total = 0.0; var num = ""
    for c in s {
        if c == "T" { continue }
        if c.isNumber { num.append(c); continue }
        guard let n = Double(num) else { return nil }
        num = ""
        switch c {
        case "W": total += n * 604800
        case "D": total += n * 86400
        case "H": total += n * 3600
        case "M": total += n * 60
        case "S": total += n
        default: return nil
        }
    }
    return sign * total
}

// Windows time zone names (used by Outlook / Teams invites) -> IANA, via system ICU (libicucore).
@_silgen_name("ucal_getTimeZoneIDForWindowsID")
func ucal_getTimeZoneIDForWindowsID(_ winid: UnsafePointer<UInt16>, _ len: Int32, _ region: UnsafePointer<CChar>?,
                                    _ id: UnsafeMutablePointer<UInt16>, _ cap: Int32, _ status: UnsafeMutablePointer<Int32>) -> Int32

func winTZ(_ name: String) -> String? {
    let w = Array(name.utf16); var buf = [UInt16](repeating: 0, count: 64); var status: Int32 = 0
    let n = ucal_getTimeZoneIDForWindowsID(w, Int32(w.count), nil, &buf, 64, &status)
    return status <= 0 && n > 0 ? String(utf16CodeUnits: buf, count: Int(n)) : nil
}

func resolveTZ(_ name: String?, warnings: inout [String]) -> TimeZone {
    guard let name, !name.isEmpty else { return TimeZone.current }
    if let tz = TimeZone(identifier: name) { return tz }
    if let id = winTZ(name), let tz = TimeZone(identifier: id) { return tz }
    warnings.append("unknown TZID '\(name)', used local time zone")
    return TimeZone.current
}

func icsDate(_ p: ICSProp, warnings: inout [String]) -> (date: Date, allDay: Bool)? {
    let v = p.value.trimmingCharacters(in: .whitespaces)
    if p.params["VALUE"] == "DATE" || v.count == 8 { return icsDayFmt.date(from: v).map { ($0, true) } }
    if v.hasSuffix("Z") { return icsUTCFmt.date(from: v).map { ($0, false) } }
    icsLocalFmt.timeZone = resolveTZ(p.params["TZID"], warnings: &warnings)
    return icsLocalFmt.date(from: v).map { ($0, false) }
}

func recurrenceRule(_ v: String, warnings: inout [String]) -> EKRecurrenceRule? {
    var kv: [String: String] = [:]
    for part in v.split(separator: ";") {
        let x = part.split(separator: "=", maxSplits: 1).map(String.init)
        if x.count == 2 { kv[x[0].uppercased()] = x[1].uppercased() }
    }
    let freq: EKRecurrenceFrequency
    switch kv["FREQ"] {
    case "DAILY": freq = .daily
    case "WEEKLY": freq = .weekly
    case "MONTHLY": freq = .monthly
    case "YEARLY": freq = .yearly
    default: warnings.append("unsupported RRULE '\(v)'"); return nil
    }
    guard let interval = Int(kv["INTERVAL"] ?? "1"), interval > 0 else {
        warnings.append("bad INTERVAL '\(kv["INTERVAL"]!)'"); return nil
    }
    var end: EKRecurrenceEnd? = nil
    if let c = kv["COUNT"] {
        guard let n = Int(c), n > 0 else { warnings.append("bad COUNT '\(c)'"); return nil }
        end = EKRecurrenceEnd(occurrenceCount: n)
    } else if let u = kv["UNTIL"] {
        // also accept '2027-01-01' / '2027-01-01T10:00:00Z'
        let v = u.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
        guard let d = icsDate(ICSProp(name: "UNTIL", params: [:], value: v), warnings: &warnings) else {
            warnings.append("bad UNTIL '\(u)' (want YYYYMMDD or YYYYMMDDTHHMMSSZ)"); return nil
        }
        end = EKRecurrenceEnd(end: d.date)
    }
    var days: [EKRecurrenceDayOfWeek]? = nil
    if let b = kv["BYDAY"] {
        let map: [String: EKWeekday] = ["SU": .sunday, "MO": .monday, "TU": .tuesday, "WE": .wednesday,
                                        "TH": .thursday, "FR": .friday, "SA": .saturday]
        days = b.split(separator: ",").compactMap { tok in
            let s = String(tok)
            guard s.count >= 2, let wd = map[String(s.suffix(2))], s.count == 2 || Int(s.dropLast(2)) != nil else {
                warnings.append("bad BYDAY value '\(s)'"); return nil
            }
            let n = Int(s.dropLast(2)) ?? 0
            return n == 0 ? EKRecurrenceDayOfWeek(wd) : EKRecurrenceDayOfWeek(dayOfTheWeek: wd, weekNumber: n)
        }
    }
    func nums(_ k: String) -> [NSNumber]? { kv[k].map { $0.split(separator: ",").compactMap { Int($0) }.map { NSNumber(value: $0) } } }
    let handled: Set<String> = ["FREQ", "INTERVAL", "COUNT", "UNTIL", "BYDAY", "BYMONTHDAY", "BYMONTH", "BYSETPOS", "WKST"]
    let extra = kv.keys.filter { !handled.contains($0) }
    if !extra.isEmpty { warnings.append("RRULE parts ignored: " + extra.sorted().joined(separator: ", ")) }
    return EKRecurrenceRule(recurrenceWith: freq, interval: interval, daysOfTheWeek: days, daysOfTheMonth: nums("BYMONTHDAY"),
                            monthsOfTheYear: nums("BYMONTH"), weeksOfTheYear: nil, daysOfTheYear: nil,
                            setPositions: nums("BYSETPOS"), end: end)
}

func importICS(_ a: [String: Any]) throws -> String {
    try needEvents()
    let text: String
    if let p = a["path"] as? String {
        let path = (p as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path) else { throw Err("cannot read \(path)") }
        guard let t = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw Err("file is not text") }
        text = t
    } else if let t = a["ics"] as? String { text = t }
    else { throw Err("path or ics required") }

    let dry = a["dry_run"] as? Bool ?? false
    let skipDup = a["skip_duplicates"] as? Bool ?? true
    let overrideAlarms: [Int]? = ints(a["alarms_minutes"])

    let target = try writableCalendar(a["calendar"] as? String)

    let events = parseEvents(text)
    if events.isEmpty { throw Err("no VEVENT found in the .ics") }
    var out: [String] = []
    var items: [[String: Any]] = []
    func note(_ status: String, _ title: String, _ text: String, _ extra: [String: Any] = [:]) {
        out.append(text); items.append(extra.merging(["status": status, "title": title]) { a, _ in a })
    }
    for ev in events {
        var warnings: [String] = []
        func prop(_ n: String) -> ICSProp? { ev.props.first { $0.name == n } }
        let title = prop("SUMMARY").map { unescapeICS($0.value) } ?? "(no title)"
        if prop("STATUS")?.value.uppercased() == "CANCELLED" { note("cancelled", title, "skipped (cancelled): \(title)"); continue }
        if prop("RECURRENCE-ID") != nil { note("instance", title, "skipped (single instance of a series): \(title)"); continue }
        guard let ds = prop("DTSTART"), let start = icsDate(ds, warnings: &warnings) else {
            note("bad_dtstart", title, "skipped (bad DTSTART): \(title)"); continue
        }
        var endDate: Date
        if let de = prop("DTEND"), let e = icsDate(de, warnings: &warnings) { endDate = e.date }
        else if let du = prop("DURATION"), let t = parseDuration(du.value) { endDate = start.date.addingTimeInterval(t) }
        else { endDate = start.date.addingTimeInterval(start.allDay ? 86400 : 3600) }
        if start.allDay { endDate = endDate.addingTimeInterval(-1) }
        if endDate < start.date { endDate = start.date }

        if skipDup {
            let pred = store.predicateForEvents(withStart: start.date.addingTimeInterval(-60), end: endDate.addingTimeInterval(60), calendars: [target])
            if store.events(matching: pred).contains(where: { $0.title == title && abs($0.startDate.timeIntervalSince(start.date)) < 60 }) {
                note("duplicate", title, "skipped (already in \(target.title)): \(title) \(fmtDate(start.date, allDay: start.allDay))",
                     ["start": fmtDate(start.date, allDay: start.allDay)]); continue
            }
        }

        var notes = prop("DESCRIPTION").map { unescapeICS($0.value) } ?? ""
        if let org = prop("ORGANIZER") {
            let mail = org.value.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
            let who = (org.params["CN"].map { "\($0) <\(mail)>" }) ?? mail
            notes += (notes.isEmpty ? "" : "\n\n") + "Organizer: \(who)"
        }
        if let uid = prop("UID") { notes += (notes.isEmpty ? "" : "\n") + "UID: \(uid.value)" }
        let location = prop("LOCATION").map { unescapeICS($0.value) }
        var url: URL? = prop("URL").flatMap { URL(string: $0.value) }
        if url == nil, let r = notes.range(of: "https://[^\\s<>\"]*(teams\\.microsoft\\.com|zoom\\.us|meet\\.google\\.com)[^\\s<>\"]*", options: .regularExpression) {
            url = URL(string: String(notes[r]))
        }
        let alarmOffsets: [TimeInterval] = overrideAlarms.map { $0.map { -Double($0) * 60 } } ?? ev.alarms
        let rule = prop("RRULE").flatMap { recurrenceRule($0.value, warnings: &warnings) }
        if prop("RRULE") != nil && rule == nil { warnings.append("event imported without recurrence") }
        var exdates: [Date] = []
        if rule != nil {
            for p in ev.props where p.name == "EXDATE" {
                for v in p.value.split(separator: ",") {
                    if let d = icsDate(ICSProp(name: "EXDATE", params: p.params, value: String(v)), warnings: &warnings) { exdates.append(d.date) }
                }
            }
        }

        let line = "\(title) \(start.allDay ? dayFmt.string(from: start.date) + " (all day)" : iso.string(from: start.date) + " - " + iso.string(from: endDate))"
        if dry {
            note("dry_run", title, "dry-run, would create in \(target.title): \(line)" + (url != nil ? " | url=\(url!.absoluteString)" : "")
                + " | alarms=\(alarmOffsets.map { Int($0 / -60) })" + (rule != nil ? " | recurring" : "")
                + (exdates.isEmpty ? "" : " | excluded=\(exdates.count)"), ["start": fmtDate(start.date, allDay: start.allDay)])
        } else {
            let e = EKEvent(eventStore: store)
            e.calendar = target
            e.title = title; e.startDate = start.date; e.endDate = endDate; e.isAllDay = start.allDay
            e.location = location; e.notes = notes.isEmpty ? nil : notes; e.url = url
            for t in alarmOffsets where t <= 0 { e.addAlarm(EKAlarm(relativeOffset: t)) }
            if let rule { e.addRecurrenceRule(rule) }
            do {
                try store.save(e, span: .futureEvents)
                // EXDATE: remove the excluded occurrences of the saved series.
                for x in exdates {
                    let pred = store.predicateForEvents(withStart: x.addingTimeInterval(-60), end: x.addingTimeInterval(60), calendars: [target])
                    // The series is already saved: a failed removal is a warning, not a failed import.
                    for o in store.events(matching: pred) where o.eventIdentifier == e.eventIdentifier && abs(o.startDate.timeIntervalSince(x)) < 60 {
                        do { try store.remove(o, span: .thisEvent) }
                        catch { warnings.append("EXDATE \(iso.string(from: x)) not removed: \(error.localizedDescription)") }
                    }
                }
                note("created", title, "created in \(target.title): \(line)" + (exdates.isEmpty ? "" : " excluded=\(exdates.count)") + " id=\(e.eventIdentifier ?? "")",
                     ["id": e.eventIdentifier ?? "", "start": fmtDate(start.date, allDay: start.allDay)])
            } catch {
                note("failed", title, "failed: \(line): \(error.localizedDescription)", ["error": error.localizedDescription])
            }
        }
        for w in warnings { out.append("  warning: \(w)") }
        if !warnings.isEmpty { items[items.count - 1]["warnings"] = warnings }
    }
    structured = ["calendar": calLabel(target), "results": items]
    return out.joined(separator: "\n")
}

// MARK: - Reminders

func listReminderLists() throws -> String {
    try needReminders()
    return store.calendars(for: .reminder).map { $0.title + ($0.allowsContentModifications ? "" : " (read-only)") }
        .joined(separator: "\n")
}

func dueDate(_ r: EKReminder) -> Date? { r.dueDateComponents.flatMap { Calendar.current.date(from: $0) } }

func fmtReminder(_ r: EKReminder) -> String {
    var due = "no due date"
    if let c = r.dueDateComponents, let d = dueDate(r) {
        due = "due " + (c.hour == nil ? dayFmt.string(from: d) : iso.string(from: d))
    }
    return "\(r.calendar.title) | \(r.isCompleted ? "[x]" : "[ ]") \(r.title ?? "") | \(due)"
        + (r.priority > 0 ? " | priority=\(r.priority)" : "")
        + (r.notes?.isEmpty == false ? " | notes=\(r.notes!.replacingOccurrences(of: "\n", with: " ").prefix(120))" : "")
        + " | id=\(r.calendarItemIdentifier)"
}

func fetchReminders(_ pred: NSPredicate) -> [EKReminder] {
    var out: [EKReminder] = []
    let sem = DispatchSemaphore(value: 0)
    store.fetchReminders(matching: pred) { out = $0 ?? []; sem.signal() }
    sem.wait()
    return out
}

func listReminders(_ a: [String: Any]) throws -> String {
    try needReminders()
    let lists = try resolveCalendars(a["list"] as? String, .reminder)
    let includeDone = a["include_completed"] as? Bool ?? false
    let pred = includeDone ? store.predicateForReminders(in: lists)
                           : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
    var items = fetchReminders(pred)
    if let days = a["due_within_days"] as? Int {
        let end = Calendar.current.date(byAdding: .day, value: days, to: Date())!
        items = items.filter { r in dueDate(r).map { $0 <= end } ?? false }
    }
    items.sort { (dueDate($0) ?? .distantFuture) < (dueDate($1) ?? .distantFuture) }
    return items.isEmpty ? "no reminders" : items.map(fmtReminder).joined(separator: "\n")
}

func setDue(_ r: EKReminder, _ s: String, alarmMinutesBefore: Int?, withAlarm: Bool) throws {
    for al in r.alarms ?? [] { r.removeAlarm(al) }
    let date = try parseDate(s)
    let hasTime = !isDateOnly(s)
    r.dueDateComponents = Calendar.current.dateComponents(hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: date)
    if hasTime && withAlarm {
        r.addAlarm(EKAlarm(absoluteDate: date.addingTimeInterval(-Double(alarmMinutesBefore ?? 0) * 60)))
    }
}

func createReminder(_ a: [String: Any]) throws -> String {
    try needReminders()
    guard let title = a["title"] as? String else { throw Err("title required") }
    let r = EKReminder(eventStore: store)
    r.title = title
    r.notes = a["notes"] as? String
    if let u = a["url"] as? String { r.url = URL(string: u) }
    if let p = a["priority"] as? Int { r.priority = p }
    r.calendar = try writableCalendar(a["list"] as? String, .reminder)
    if let d = a["due"] as? String {
        try setDue(r, d, alarmMinutesBefore: a["alarm_minutes_before"] as? Int, withAlarm: a["alarm"] as? Bool ?? true)
    }
    try store.save(r, commit: true)
    return "created: " + fmtReminder(r)
}

func findReminder(_ a: [String: Any]) throws -> EKReminder {
    try needReminders()
    guard let id = a["id"] as? String, let r = store.calendarItem(withIdentifier: id) as? EKReminder else { throw Err("reminder id not found") }
    return r
}

func updateReminder(_ a: [String: Any]) throws -> String {
    let r = try findReminder(a)
    if let t = a["title"] as? String { r.title = t }
    if let n = a["notes"] as? String { r.notes = n }
    if let u = a["url"] as? String { r.url = u.isEmpty ? nil : URL(string: u) }
    if let p = a["priority"] as? Int { r.priority = p }
    if let c = a["completed"] as? Bool { r.isCompleted = c }
    if let name = a["list"] as? String, !name.isEmpty { r.calendar = try writableCalendar(name, .reminder) }
    if let d = a["due"] as? String {
        if d.isEmpty || d == "none" {
            r.dueDateComponents = nil
            for al in r.alarms ?? [] { r.removeAlarm(al) }
        } else { try setDue(r, d, alarmMinutesBefore: a["alarm_minutes_before"] as? Int, withAlarm: a["alarm"] as? Bool ?? true) }
    }
    try store.save(r, commit: true)
    return "updated: " + fmtReminder(r)
}

func deleteReminder(_ a: [String: Any]) throws -> String {
    let r = try findReminder(a)
    let t = r.title ?? ""
    try store.remove(r, commit: true)
    return "deleted: \(t)"
}

// MARK: - MCP plumbing

let toolSchemas: [[String: Any]] = [
    ["name": "list_calendars", "description": "List Apple Calendar calendars with account (source), read-only and default flags. If two calendars share a title, address them as 'Title (Source)'.",
     "inputSchema": ["type": "object", "properties": [:] as [String: Any]]],
    ["name": "list_events", "description": "List events in a date range, sorted by start. Default: from the start of today, 7 days. Recurring events are expanded into occurrences; each shows occurrence_start, needed by get/update/delete to target that one occurrence.",
     "inputSchema": ["type": "object", "properties": [
        "from": ["type": "string", "description": "'YYYY-MM-DD' or 'YYYY-MM-DD HH:MM', default start of today"],
        "to": ["type": "string", "description": "'YYYY-MM-DD' (inclusive day) or 'YYYY-MM-DD HH:MM'; overrides days"],
        "days": ["type": "integer", "description": "days from 'from', default 7"],
        "calendar": ["type": "string", "description": "calendar name, default all"]]]],
    ["name": "search_events", "description": "Find events whose title, location or notes contain the query (case- and accent-insensitive). Default range: 30 days back to 90 days ahead (120 days from 'from').",
     "inputSchema": ["type": "object", "properties": [
        "query": ["type": "string"],
        "from": ["type": "string", "description": "default today - 30 days"],
        "to": ["type": "string", "description": "default 'from' + days"],
        "days": ["type": "integer", "description": "days from 'from', default 120"],
        "calendar": ["type": "string", "description": "calendar name, default all"],
        "limit": ["type": "integer", "description": "max results, default 50"]],
        "required": ["query"]]],
    ["name": "get_event", "description": "Full details of one event: notes, url, recurrence (RRULE), alarms, organizer, attendees with status, calendar account.",
     "inputSchema": ["type": "object", "properties": [
        "id": ["type": "string", "description": "id from list_events/search_events"],
        "occurrence_start": ["type": "string", "description": "for recurring events: start of the occurrence, as listed"]],
        "required": ["id"]]],
    ["name": "create_event", "description": "Create a calendar event. Goes to the default calendar unless 'calendar' is given.",
     "inputSchema": ["type": "object", "properties": [
        "summary": ["type": "string"],
        "start": ["type": "string", "description": "'YYYY-MM-DD HH:MM' local time, or 'YYYY-MM-DD' with all_day"],
        "end": ["type": "string", "description": "default start + 1h; for all_day the last day (inclusive), default = start"],
        "all_day": ["type": "boolean"],
        "calendar": ["type": "string"], "location": ["type": "string"], "notes": ["type": "string"], "url": ["type": "string"],
        "alarms_minutes": ["type": "array", "items": ["type": "integer"], "description": "alerts, minutes before start, e.g. [1440, 30]"],
        "recurrence": ["type": "string", "description": "RRULE, e.g. 'FREQ=WEEKLY;BYDAY=MO,WE;COUNT=10' or 'FREQ=MONTHLY;BYMONTHDAY=15;UNTIL=20270101'"]],
        "required": ["summary", "start"]]],
    ["name": "update_event", "description": "Change an event. Pass only fields to change; empty string clears location/notes/url. For recurring events pass occurrence_start to pick the occurrence and span='future' to apply to it and all later ones (changing recurrence or calendar always applies to the series from that point). 'calendar' moves the event.",
     "inputSchema": ["type": "object", "properties": [
        "id": ["type": "string"], "occurrence_start": ["type": "string"],
        "span": ["type": "string", "description": "'this' (default) or 'future'"],
        "summary": ["type": "string"], "start": ["type": "string", "description": "keeps duration if end not given"],
        "end": ["type": "string"], "all_day": ["type": "boolean"],
        "location": ["type": "string"], "notes": ["type": "string"], "url": ["type": "string"],
        "calendar": ["type": "string", "description": "move to this calendar"],
        "alarms_minutes": ["type": "array", "items": ["type": "integer"], "description": "replaces all alerts; [] removes them"],
        "recurrence": ["type": "string", "description": "RRULE, or 'none' to stop repeating"]],
        "required": ["id"]]],
    ["name": "delete_event", "description": "Delete an event by id. For recurring events pass occurrence_start to pick the occurrence; span='future' deletes it and all later occurrences.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "string"],
        "occurrence_start": ["type": "string"],
        "span": ["type": "string", "description": "'this' (default) or 'future'"]], "required": ["id"]]],
    ["name": "import_ics", "description": "Import events from an .ics file (or raw .ics text) straight into a calendar, no dialog. Handles time zones (incl. Outlook/Teams Windows names), all-day events, location, join URL, organizer (stored in notes), alarms and basic recurrence. Skips duplicates (same title and start) by default.",
     "inputSchema": ["type": "object", "properties": [
        "path": ["type": "string", "description": "path to an .ics file (~ allowed)"],
        "ics": ["type": "string", "description": "raw .ics text, alternative to path"],
        "calendar": ["type": "string", "description": "target calendar name, default: the default calendar"],
        "dry_run": ["type": "boolean", "description": "parse and report only, do not save"],
        "skip_duplicates": ["type": "boolean", "description": "default true"],
        "alarms_minutes": ["type": "array", "items": ["type": "integer"], "description": "override alarms: minutes before start, e.g. [1440, 30]"]]]],
    ["name": "list_reminder_lists", "description": "List Apple Reminders lists.",
     "inputSchema": ["type": "object", "properties": [:] as [String: Any]]],
    ["name": "list_reminders", "description": "List reminders (incomplete by default), sorted by due date.",
     "inputSchema": ["type": "object", "properties": [
        "list": ["type": "string", "description": "list name, default all"],
        "include_completed": ["type": "boolean"],
        "due_within_days": ["type": "integer", "description": "only reminders due within N days (incl. overdue)"]]]],
    ["name": "create_reminder", "description": "Create a reminder. 'due' is 'YYYY-MM-DD HH:MM' (alert fires at that time) or 'YYYY-MM-DD' (no alert).",
     "inputSchema": ["type": "object", "properties": [
        "title": ["type": "string"], "notes": ["type": "string"], "url": ["type": "string"],
        "list": ["type": "string", "description": "default list if omitted"],
        "due": ["type": "string"],
        "alarm": ["type": "boolean", "description": "alert at due time, default true"],
        "alarm_minutes_before": ["type": "integer", "description": "alert this many minutes before due, default 0"],
        "priority": ["type": "integer", "description": "0 none, 1 high, 5 medium, 9 low"]],
        "required": ["title"]]],
    ["name": "update_reminder", "description": "Update a reminder by id. Pass only fields to change; due 'none' clears the due date; completed=true marks it done.",
     "inputSchema": ["type": "object", "properties": [
        "id": ["type": "string"], "title": ["type": "string"], "notes": ["type": "string"], "url": ["type": "string"],
        "list": ["type": "string"], "due": ["type": "string"], "alarm": ["type": "boolean"],
        "alarm_minutes_before": ["type": "integer"], "priority": ["type": "integer"], "completed": ["type": "boolean"]],
        "required": ["id"]]],
    ["name": "delete_reminder", "description": "Delete a reminder by id.",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]]],
]

func callTool(_ name: String, _ args: [String: Any]) throws -> String {
    switch name {
    case "list_calendars": return try listCalendars()
    case "list_events": return try listEvents(args)
    case "search_events": return try searchEvents(args)
    case "get_event": return try getEvent(args)
    case "update_event": return try updateEvent(args)
    case "create_event": return try createEvent(args)
    case "delete_event": return try deleteEvent(args)
    case "import_ics": return try importICS(args)
    case "list_reminder_lists": return try listReminderLists()
    case "list_reminders": return try listReminders(args)
    case "create_reminder": return try createReminder(args)
    case "update_reminder": return try updateReminder(args)
    case "delete_reminder": return try deleteReminder(args)
    default: throw Err("unknown tool \(name)")
    }
}

func send(_ obj: [String: Any]) {
    let d = try! JSONSerialization.data(withJSONObject: obj)
    FileHandle.standardOutput.write(d + "\n".data(using: .utf8)!)
}

eventsAccessError = requestAccess(.event)
remindersAccessError = requestAccess(.reminder)
if let e = eventsAccessError { FileHandle.standardError.write(Data(("calendar: " + e + "\n").utf8)) }
if let e = remindersAccessError { FileHandle.standardError.write(Data(("reminders: " + e + "\n").utf8)) }

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty,
          let req = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
          let id = req["id"] else { continue }
    let method = req["method"] as? String ?? ""
    let params = req["params"] as? [String: Any] ?? [:]
    var result: [String: Any]
    switch method {
    case "initialize":
        let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]
        let asked = params["protocolVersion"] as? String ?? ""
        result = ["protocolVersion": supported.contains(asked) ? asked : supported[0],
                  "capabilities": ["tools": [:] as [String: Any]],
                  "serverInfo": ["name": "apple-calendar", "version": "0.4.0"]]
    case "ping":
        result = [:]
    case "tools/list":
        result = ["tools": toolSchemas]
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        structured = nil
        NSTimeZone.resetSystemTimeZone()  // pick up a time-zone change (travel) without restart
        // No run loop here, so EKEventStoreChanged is never delivered and the store cache goes
        // stale (calendars/events changed in Calendar.app stay invisible). Refetch per call.
        store.reset()
        do {
            result = ["content": [["type": "text", "text": try callTool(name, args)]]]
            if let s = structured { result["structuredContent"] = s }
        }
        catch { result = ["content": [["type": "text", "text": "error: \(error.localizedDescription)"]], "isError": true] }
    default:
        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "unknown method \(method)"]])
        continue
    }
    send(["jsonrpc": "2.0", "id": id, "result": result])
}
