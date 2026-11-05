import EventKit
import GleanerCore
import OSLog

private let log = Logger(subsystem: "app.gleaner.Gleaner", category: "calendar")

/// Today's events and reminders from the system Calendar and Reminders.
@MainActor
final class CalendarService {
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    static var canReadEvents: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    static var canReadReminders: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    /// Asks for calendar and reminders access; returns whether either was granted.
    func requestAccess() async -> Bool {
        let events = Self.canReadEvents ? true : ((try? await store.requestFullAccessToEvents()) ?? false)
        let reminders = Self.canReadReminders ? true : ((try? await store.requestFullAccessToReminders()) ?? false)
        return events || reminders
    }

    /// Calls `onChange` whenever calendars or reminders change.
    func observeChanges(_ onChange: @escaping @MainActor () -> Void) {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { onChange() }
        }
    }

    /// Timed events that have not ended yet today, and today's open reminders.
    func today(now: Date = Date()) async -> [CalendarEvent] {
        let reminders = await todaysReminders(now: now)
        let items = todaysEvents(now: now) + reminders
        log.info("Calendar: \(items.count - reminders.count) events, \(reminders.count) reminders today")
        return items
    }

    /// Adds a confirmed suggestion to Calendar or Reminders. Returns whether it was saved.
    func add(_ suggestion: ScheduleSuggestion, source: String) async -> Bool {
        let notes = [suggestion.notes, source].filter { !$0.isEmpty }.joined(separator: "\n")
        switch suggestion.kind {
        case .reminder:
            return await addReminder(title: suggestion.title, notes: notes,
                                     due: DueDateParser.Due(date: suggestion.start, hasTime: !suggestion.allDay))
        case .event:
            var granted = Self.canReadEvents
            if !granted { granted = (try? await store.requestFullAccessToEvents()) ?? false }
            guard granted, let calendar = store.defaultCalendarForNewEvents else { return false }
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = suggestion.title
            event.notes = notes.isEmpty ? nil : notes
            event.location = suggestion.location.isEmpty ? nil : suggestion.location
            event.isAllDay = suggestion.allDay
            event.startDate = suggestion.start
            event.endDate = suggestion.allDay ? suggestion.start : suggestion.effectiveEnd
            if !suggestion.allDay { event.addAlarm(EKAlarm(relativeOffset: -15 * 60)) }
            do {
                try store.save(event, span: .thisEvent, commit: true)
                return true
            } catch {
                log.error("Adding event failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
    }

    /// Adds a reminder, with an alert at `due` when the time is known. Returns whether it was saved.
    func addReminder(title: String, notes: String, due: DueDateParser.Due?) async -> Bool {
        var granted = Self.canReadReminders
        if !granted { granted = (try? await store.requestFullAccessToReminders()) ?? false }
        guard granted, let list = store.defaultCalendarForNewReminders() else { return false }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = title
        reminder.notes = notes.isEmpty ? nil : notes
        if let due {
            let fields: Set<Calendar.Component> = due.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(fields, from: due.date)
            if due.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due.date)) }
        }
        do {
            try store.save(reminder, commit: true)
            return true
        } catch {
            log.error("Adding reminder failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Adds a calendar event: an hour at `due`'s time, or all day. Returns whether it was saved.
    func addEvent(title: String, notes: String, due: DueDateParser.Due) async -> Bool {
        var granted = Self.canReadEvents
        if !granted { granted = (try? await store.requestFullAccessToEvents()) ?? false }
        guard granted, let calendar = store.defaultCalendarForNewEvents else { return false }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.notes = notes.isEmpty ? nil : notes
        event.startDate = due.date
        event.endDate = due.hasTime ? due.date.addingTimeInterval(3600) : due.date
        event.isAllDay = !due.hasTime
        if due.hasTime { event.addAlarm(EKAlarm(relativeOffset: -15 * 60)) }
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return true
        } catch {
            log.error("Adding event failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Marks a reminder done in Reminders.
    func completeReminder(id: String) {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
        } catch {
            log.error("Completing reminder failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func todaysEvents(now: Date) -> [CalendarEvent] {
        guard Self.canReadEvents, let (start, end) = Self.dayBounds(of: now) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .map { event in
                CalendarEvent(
                    id: event.calendarItemIdentifier,
                    title: event.title ?? "",
                    start: event.startDate,
                    end: event.endDate,
                    location: event.location ?? "",
                    meeting: MeetingLinkDetector.link(in: [event.url?.absoluteString, event.location, event.notes])
                )
            }
    }

    private func todaysReminders(now: Date) async -> [CalendarEvent] {
        guard Self.canReadReminders, let (start, end) = Self.dayBounds(of: now) else { return [] }
        // Include reminders that were due earlier and are still open.
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: start, ending: end, calendars: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let items = (reminders ?? []).compactMap { reminder -> CalendarEvent? in
                    guard let components = reminder.dueDateComponents,
                          let due = Calendar.current.date(from: components) else { return nil }
                    return CalendarEvent(
                        id: reminder.calendarItemIdentifier,
                        kind: .reminder,
                        title: reminder.title ?? "",
                        start: due,
                        end: due,
                        hasTime: components.hour != nil,
                        notes: (reminder.notes ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
                            .trimmingCharacters(in: .whitespaces),
                        meeting: MeetingLinkDetector.link(in: [reminder.url?.absoluteString, reminder.notes])
                    )
                }
                continuation.resume(returning: items)
            }
        }
    }

    private static func dayBounds(of date: Date) -> (Date, Date)? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return (start, end)
    }
}
