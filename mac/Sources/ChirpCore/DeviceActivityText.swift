import Foundation

/// What Settings → Devices and the Activity sheet say about device activity, in words. Pure, with the clock, locale and
/// time zone injectable, so tests (and snapshots) read the same text on any day.
public enum ActivityText {
    public static let keepTitle = "Keep device activity"
    public static let keepHelp = "Keeps a list of which device used this Mac’s server, when and for what, on this Mac only. Never what was said or written. Turning it off deletes the list."
    public static let keepOff = "Device activity is off. Nothing is recorded."
    public static let outdated = "Update chirp-server to see device activity."
    public static let showButton = "Activity…"
    public static let sheetTitle = "Device activity"
    public static let allDevices = "All devices"
    public static let empty = "No requests yet."
    public static let thisMac = "This Mac"
    public static let sharedToken = "Shared token"
    public static let unknownDevice = "Unknown device"

    public static let columns = ["Time", "Device", "What", "Length", "Result"]

    public static func keepFailure(_ error: ActivityError) -> String {
        switch error {
        case .hidden: "The server did not allow that change, so nothing changed."
        case .outdated: outdated
        case .failed: "Can’t reach the server, so nothing changed."
        }
    }

    public static func confirmOffTitle() -> String { "Turn off device activity?" }
    public static let confirmOffDetail = "Chirp stops recording which device used the server and deletes the list it has kept."

    // MARK: names

    public static func kindName(_ kind: ActivityKind) -> String {
        switch kind {
        case .dictation: "Dictation"
        case .notesSegment: "Notes"
        case .transcribe: "Transcribe"
        case .notesStructure: "Notes clean-up"
        case .notesReorganize: "Organize"
        case .notesEdit: "Voice edit"
        case .speakerModel: "Speaker model"
        case .other: "Other"
        }
    }

    public static func outcomeName(_ outcome: ActivityOutcome) -> String {
        switch outcome {
        case .ok: "OK"
        case .cancelled: "Cancelled"
        case .rejected: "Clean-up rejected"
        case .timeout: "Timed out"
        case .busy: "Busy"
        case .preempted: "Interrupted"
        case .disconnected: "Disconnected"
        case .other(let code): code.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    public static func clientName(_ client: String) -> String {
        switch client {
        case "android": "Android"
        case "ios": "iOS"
        case "mac": "Mac"
        case "desktop": "Desktop"
        default: client
        }
    }

    /// The device column: a phone's name (and "revoked"), This Mac, or the shared token with its client.
    public static func sourceName(_ source: ActivitySource, client: String? = nil) -> String {
        switch source {
        case .device(_, let name, let revoked): (name ?? unknownDevice) + (revoked ? " (revoked)" : "")
        case .local: thisMac
        case .shared: client.map { "\(sharedToken) · \(clientName($0))" } ?? sharedToken
        case .other: unknownDevice
        }
    }

    // MARK: times and lengths

    private static func relative(_ date: Date, now: Date, locale: Locale) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: now)
    }

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// "10:14", in the local time zone.
    public static func clock(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar(timeZone), timeZone: timeZone))
    }

    /// The table's Time column: the clock time today, else the day and time.
    public static func when(_ date: Date, now: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let cal = calendar(timeZone)
        if cal.isDate(date, inSameDayAs: now) { return clock(date, locale: locale, timeZone: timeZone) }
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: cal, timeZone: timeZone)
        return date.formatted(style)
    }

    /// "4 seconds", "1 second", "2 min 5 s", or "—" for none.
    public static func length(_ milliseconds: Int?) -> String {
        guard let milliseconds, milliseconds >= 0 else { return "—" }
        let seconds = Int((Double(milliseconds) / 1000).rounded())
        if seconds < 60 { return seconds == 1 ? "1 second" : "\(seconds) seconds" }
        return "\(seconds / 60) min \(seconds % 60) s"
    }

    /// What the Length column shows: the audio's length for an audio request, else how long the request took.
    public static func length(of event: ActivityEvent) -> String {
        length(event.kind.hasAudio ? event.audioMS : event.durationMS)
    }

    // MARK: rows

    /// `In use now · Dictation` for the first request of `source` that is running.
    public static func inUse(_ request: ActiveRequest) -> String { "In use now · \(kindName(request.kind))" }

    /// How many events of `source` fall on `now`'s local calendar day.
    public static func requestsToday(_ events: [ActivityEvent], source matches: (ActivitySource) -> Bool, now: Date, timeZone: TimeZone = .current) -> Int {
        let cal = calendar(timeZone)
        return events.filter { matches($0.source) && cal.isDate($0.at, inSameDayAs: now) }.count
    }

    /// `Last: Notes clean-up 3 min ago · 12 requests today`, or nil when `source` has no event.
    public static func last(_ events: [ActivityEvent], source matches: (ActivitySource) -> Bool, now: Date,
                            locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard let newest = events.first(where: { matches($0.source) }) else { return nil }
        var text = "Last: \(kindName(newest.kind)) \(relative(newest.at, now: now, locale: locale))"
        let today = requestsToday(events, source: matches, now: now, timeZone: timeZone)
        if today > 0 { text += " · \(today) \(today == 1 ? "request" : "requests") today" }
        return text
    }

    /// The second detail line of a row: in use now, else the last request, else nothing.
    public static func line(_ activity: DeviceActivity, source matches: (ActivitySource) -> Bool, now: Date,
                            locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        if let running = activity.active.first(where: { matches($0.source) }) { return inUse(running) }
        return last(activity.events, source: matches, now: now, locale: locale, timeZone: timeZone)
    }

    /// The clients (`Android`, `iOS`) a source used, for the shared-token row.
    public static func clients(_ activity: DeviceActivity, source matches: (ActivitySource) -> Bool) -> [String] {
        var seen: [String] = []
        let all = activity.active.filter { matches($0.source) }.map(\.client) + activity.events.filter { matches($0.source) }.map(\.client)
        for client in all {
            guard let client, !seen.contains(client) else { continue }
            seen.append(client)
        }
        return seen.map(clientName)
    }

    /// Whether `source` has any activity to show.
    public static func has(_ activity: DeviceActivity, source matches: (ActivitySource) -> Bool) -> Bool {
        activity.active.contains { matches($0.source) } || activity.events.contains { matches($0.source) }
    }

    // MARK: refusals

    /// `3 refused requests with an unknown token · last 5 min ago`, `Old Pixel (revoked) tried 2 times · last 1 h ago`.
    public static func refusal(_ r: Refusal, now: Date, locale: Locale = .current) -> String {
        let ago = relative(r.last, now: now, locale: locale)
        switch r.reason {
        case .revoked:
            let name = r.deviceName ?? unknownDevice
            let tried = r.count == 1 ? "tried once" : "tried \(r.count) times"
            return "\(name) (revoked) \(tried) · last \(ago)"
        case .unknownToken:
            return "\(r.count) refused \(r.count == 1 ? "request" : "requests") with an unknown token · last \(ago)"
        case .noToken:
            return "\(r.count) refused \(r.count == 1 ? "request" : "requests") with no token · last \(ago)"
        case .other:
            return "\(r.count) refused \(r.count == 1 ? "request" : "requests") · last \(ago)"
        }
    }

    // MARK: the sheet

    public static func footer(_ activity: DeviceActivity, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let days = activity.maxAgeDays
        let kept = "Chirp keeps the last \(days) \(days == 1 ? "day" : "days") (up to \(activity.maxEvents.formatted(.number.locale(locale))) requests) on this Mac, in the server’s data folder."
        return "Since chirp-server started at \(clock(activity.started, locale: locale, timeZone: timeZone)). "
            + kept + " Only the time, device, kind of request, length and result. Never what was said or written."
    }

    /// One sentence per row for VoiceOver: "Pixel 8, Dictation, 4 seconds, OK, 10:14".
    public static func spoken(_ event: ActivityEvent, now: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        [sourceName(event.source, client: event.client), kindName(event.kind), length(of: event), outcomeName(event.outcome),
         when(event.at, now: now, locale: locale, timeZone: timeZone)].joined(separator: ", ")
    }

    /// The device filter's choices, from what the events and running requests show (a rename or revoke is the same device).
    public static func filterChoices(_ activity: DeviceActivity) -> [ActivitySource] {
        var seen: [ActivitySource] = []
        for source in activity.active.map(\.source) + activity.events.map(\.source) where !seen.contains(where: { identity($0) == identity(source) }) {
            seen.append(source)
        }
        return seen
    }

    /// What makes two sources the same device (a rename or revoke does not).
    public static func identity(_ source: ActivitySource) -> String {
        switch source {
        case .device(let id, _, _): "device:\(id)"
        case .local: "local"
        case .shared: "shared"
        case .other(let kind): "other:\(kind)"
        }
    }
}
