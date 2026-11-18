import EventKit
import Foundation

enum AppleIntegrationError: LocalizedError, Equatable {
    case permissionDenied
    case missingReminderCalendar
    case missingEventCalendar
    case missingCreatedIdentifier

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Permission was denied."
        case .missingReminderCalendar:
            "No default Reminders list is available."
        case .missingEventCalendar:
            "No default Calendar is available."
        case .missingCreatedIdentifier:
            "The item was created, but no Apple identifier was returned."
        }
    }
}

enum AppleIntegrationService {
    static func createReminder(from node: CanvasNode, completion: @escaping (Result<String, Error>) -> Void) {
        let eventStore = EKEventStore()

        eventStore.requestFullAccessToReminders { granted, error in
            if let error {
                complete(.failure(error), completion)
                return
            }

            guard granted else {
                complete(.failure(AppleIntegrationError.permissionDenied), completion)
                return
            }

            guard let calendar = eventStore.defaultCalendarForNewReminders() else {
                complete(.failure(AppleIntegrationError.missingReminderCalendar), completion)
                return
            }

            let reminder = EKReminder(eventStore: eventStore)
            reminder.title = sanitizedTitle(from: node)
            reminder.notes = node.body.isEmpty ? nil : node.body
            reminder.priority = reminderPriority(from: node.priority)
            reminder.calendar = calendar

            if let dueDate = node.dueDate {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: dueDate
                )
            }

            if node.progress >= 100 {
                reminder.isCompleted = true
                reminder.completionDate = node.completedAt ?? Date()
            }

            do {
                try eventStore.save(reminder, commit: true)
                guard !reminder.calendarItemIdentifier.isEmpty else {
                    complete(.failure(AppleIntegrationError.missingCreatedIdentifier), completion)
                    return
                }

                complete(.success(reminder.calendarItemIdentifier), completion)
            } catch {
                complete(.failure(error), completion)
            }
        }
    }

    static func createCalendarEvent(from node: CanvasNode, completion: @escaping (Result<String, Error>) -> Void) {
        let eventStore = EKEventStore()

        eventStore.requestWriteOnlyAccessToEvents { granted, error in
            if let error {
                complete(.failure(error), completion)
                return
            }

            guard granted else {
                complete(.failure(AppleIntegrationError.permissionDenied), completion)
                return
            }

            guard let calendar = eventStore.defaultCalendarForNewEvents else {
                complete(.failure(AppleIntegrationError.missingEventCalendar), completion)
                return
            }

            let startDate = node.startDate ?? Date()
            let endDate = validEndDate(from: node.dueDate, after: startDate)

            let event = EKEvent(eventStore: eventStore)
            event.title = sanitizedTitle(from: node)
            event.notes = calendarNotes(from: node)
            event.startDate = startDate
            event.endDate = endDate
            event.calendar = calendar

            do {
                try eventStore.save(event, span: .thisEvent, commit: true)
                guard let eventIdentifier = event.eventIdentifier,
                      !eventIdentifier.isEmpty else {
                    complete(.failure(AppleIntegrationError.missingCreatedIdentifier), completion)
                    return
                }

                complete(.success(eventIdentifier), completion)
            } catch {
                complete(.failure(error), completion)
            }
        }
    }

    private static func sanitizedTitle(from node: CanvasNode) -> String {
        let title = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled" : title
    }

    static func reminderPriority(from priority: TaskPriority) -> Int {
        switch priority {
        case .none:
            0
        case .low:
            9
        case .medium:
            5
        case .high:
            1
        }
    }

    private static func calendarNotes(from node: CanvasNode) -> String? {
        var parts: [String] = []

        let body = node.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            parts.append(body)
        }

        let webLinks = node.links
            .filter { $0.linkType == .web }
            .map(\.urlString)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if !webLinks.isEmpty {
            parts.append("Links:\n\(webLinks.joined(separator: "\n"))")
        }

        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    static func validEndDate(from dueDate: Date?, after startDate: Date) -> Date {
        guard let dueDate,
              dueDate > startDate else {
            return startDate.addingTimeInterval(30 * 60)
        }

        return dueDate
    }

    private static func complete(_ result: Result<String, Error>, _ completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.main.async {
            completion(result)
        }
    }
}

// MARK: - Two-way sync

struct AppleSyncReport {
    var pulled = 0
    var pushed = 0
    var unlinked = 0
    var checked = 0
    var errors: [String] = []

    var summary: String {
        guard checked > 0 else {
            return "No topics are linked to Apple Reminders or Calendar yet."
        }
        var parts = ["Checked \(checked) linked item(s)"]
        parts.append(pulled > 0 ? "\(pulled) updated from Apple" : "nothing new from Apple")
        if pushed > 0 {
            parts.append("\(pushed) sent to Apple")
        }
        if unlinked > 0 {
            parts.append("\(unlinked) link(s) removed because the Apple item was deleted")
        }
        var text = parts.joined(separator: ", ") + "."
        if !errors.isEmpty {
            text += "\n\n" + errors.prefix(3).joined(separator: "\n")
        }
        return text
    }
}

extension AppleIntegrationService {
    /// The values a topic contributes to its reminder.
    static func reminderValues(of node: CanvasNode, now: Date = Date()) -> AppleSyncBaseline {
        AppleSyncBaseline(
            title: sanitizedTitle(node),
            notes: node.body,
            startDate: nil,
            dueDate: node.dueDate,
            isCompleted: node.isTaskCompleted,
            priority: node.priority,
            syncedAt: now
        )
    }

    /// Two-way sync of every linked reminder and event (3-way merge against the last synced values).
    /// Conflicts: Apple wins for completion, dates and priority (usually changed on the phone),
    /// the map wins for title and notes.
    @MainActor
    static func sync(nodes: [CanvasNode], now: Date = Date()) async -> (nodes: [CanvasNode], report: AppleSyncReport) {
        var nodes = nodes
        var report = AppleSyncReport()
        let hasReminders = nodes.contains { $0.appleReminderID != nil }
        let hasEvents = nodes.contains { $0.appleCalendarEventID != nil }
        guard hasReminders || hasEvents else {
            return (nodes, report)
        }

        let store = EKEventStore()
        var remindersAllowed = false
        var eventsAllowed = false
        if hasReminders {
            remindersAllowed = (try? await store.requestFullAccessToReminders()) ?? false
            if !remindersAllowed {
                report.errors.append("Reminders: access was denied (System Settings ▸ Privacy & Security ▸ Reminders).")
            }
        }
        if hasEvents {
            eventsAllowed = (try? await store.requestFullAccessToEvents()) ?? false
            if !eventsAllowed {
                report.errors.append("Calendar: full access is needed to read changes (System Settings ▸ Privacy & Security ▸ Calendars).")
            }
        }

        for index in nodes.indices {
            if remindersAllowed, let id = nodes[index].appleReminderID {
                report.checked += 1
                syncReminder(id: id, node: &nodes[index], store: store, report: &report, now: now)
            }
            if eventsAllowed, let id = nodes[index].appleCalendarEventID {
                report.checked += 1
                syncEvent(id: id, node: &nodes[index], store: store, report: &report, now: now)
            }
        }
        do {
            try store.commit()
        } catch {
            report.errors.append("Saving to Apple failed: \(error.localizedDescription)")
        }
        return (nodes, report)
    }

    /// Creates reminders for several topics at once; returns the new identifiers by topic.
    @MainActor
    static func createReminders(for nodes: [CanvasNode], now: Date = Date()) async throws -> [UUID: String] {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else {
            throw AppleIntegrationError.permissionDenied
        }
        guard let calendar = store.defaultCalendarForNewReminders() else {
            throw AppleIntegrationError.missingReminderCalendar
        }
        var created: [UUID: String] = [:]
        for node in nodes {
            let reminder = EKReminder(eventStore: store)
            reminder.calendar = calendar
            apply(reminderValues(of: node, now: now), to: reminder)
            try store.save(reminder, commit: false)
            created[node.id] = reminder.calendarItemIdentifier
        }
        try store.commit()
        return created
    }

    // MARK: Merge

    private static func syncReminder(id: String, node: inout CanvasNode, store: EKEventStore, report: inout AppleSyncReport, now: Date) {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            node.appleReminderID = nil
            node.appleSync?.reminder = nil
            report.unlinked += 1
            return
        }
        let local = reminderValues(of: node, now: now)
        let remote = AppleSyncBaseline(
            title: reminder.title ?? "",
            notes: reminder.notes ?? "",
            startDate: nil,
            dueDate: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
            isCompleted: reminder.isCompleted,
            priority: taskPriority(fromReminderPriority: reminder.priority),
            syncedAt: now
        )
        // First sync of an older link: treat the map as the agreed state, so Apple's edits come in.
        let base = node.appleSync?.reminder ?? local
        var merged = local
        var pulled = false
        var pushed = false

        func merge<T: Equatable>(_ key: WritableKeyPath<AppleSyncBaseline, T>, appleWins: Bool, same: (T, T) -> Bool = { $0 == $1 }) {
            let localChanged = !same(local[keyPath: key], base[keyPath: key])
            let remoteChanged = !same(remote[keyPath: key], base[keyPath: key])
            if remoteChanged && (!localChanged || appleWins) {
                merged[keyPath: key] = remote[keyPath: key]
                if !same(remote[keyPath: key], local[keyPath: key]) { pulled = true }
            } else if !same(local[keyPath: key], remote[keyPath: key]) {
                pushed = true
            }
        }
        merge(\.title, appleWins: false)
        merge(\.notes, appleWins: false)
        merge(\.dueDate, appleWins: true, same: sameDate)
        merge(\.isCompleted, appleWins: true)
        merge(\.priority, appleWins: true)

        if pulled {
            applyToNode(merged, includeStart: false, node: &node, completionDate: reminder.completionDate, now: now)
            report.pulled += 1
        }
        if pushed {
            apply(merged, to: reminder)
            do {
                try store.save(reminder, commit: false)
                report.pushed += 1
            } catch {
                report.errors.append("Reminder “\(merged.title)”: \(error.localizedDescription)")
            }
        }
        if node.appleSync == nil {
            node.appleSync = AppleSyncState()
        }
        node.appleSync?.reminder = merged
    }

    private static func syncEvent(id: String, node: inout CanvasNode, store: EKEventStore, report: inout AppleSyncReport, now: Date) {
        guard let event = store.event(withIdentifier: id) else {
            node.appleCalendarEventID = nil
            node.appleSync?.event = nil
            report.unlinked += 1
            return
        }
        let remote = AppleSyncBaseline(title: event.title ?? "", notes: "", startDate: event.startDate, dueDate: event.endDate,
                                       isCompleted: false, priority: .none, syncedAt: now)
        let previous = node.appleSync?.event
        // A topic without its own dates follows the event's dates.
        let local = AppleSyncBaseline(title: sanitizedTitle(node), notes: "",
                                      startDate: node.startDate ?? previous?.startDate ?? remote.startDate,
                                      dueDate: node.dueDate ?? previous?.dueDate ?? remote.dueDate,
                                      isCompleted: false, priority: .none, syncedAt: now)
        let base = previous ?? local
        var merged = local
        var pulled = false
        var pushed = false

        func merge<T: Equatable>(_ key: WritableKeyPath<AppleSyncBaseline, T>, appleWins: Bool, same: (T, T) -> Bool = { $0 == $1 }) {
            let localChanged = !same(local[keyPath: key], base[keyPath: key])
            let remoteChanged = !same(remote[keyPath: key], base[keyPath: key])
            if remoteChanged && (!localChanged || appleWins) {
                merged[keyPath: key] = remote[keyPath: key]
                if !same(remote[keyPath: key], local[keyPath: key]) { pulled = true }
            } else if !same(local[keyPath: key], remote[keyPath: key]) {
                pushed = true
            }
        }
        merge(\.title, appleWins: false)
        merge(\.startDate, appleWins: true, same: sameDate)
        merge(\.dueDate, appleWins: true, same: sameDate)

        if pulled {
            node.title = merged.title
            if node.startDate != nil || previous != nil { node.startDate = merged.startDate }
            if node.dueDate != nil || previous != nil { node.dueDate = merged.dueDate }
            report.pulled += 1
        }
        if pushed, let start = merged.startDate {
            event.title = merged.title
            event.startDate = start
            event.endDate = validEndDate(from: merged.dueDate, after: start)
            do {
                try store.save(event, span: .thisEvent, commit: false)
                report.pushed += 1
            } catch {
                report.errors.append("Event “\(merged.title)”: \(error.localizedDescription)")
            }
        }
        if node.appleSync == nil {
            node.appleSync = AppleSyncState()
        }
        node.appleSync?.event = merged
    }

    private static func applyToNode(_ values: AppleSyncBaseline, includeStart: Bool, node: inout CanvasNode, completionDate: Date?, now: Date) {
        if values.title != sanitizedTitle(node) {
            node.title = values.title
        }
        node.body = values.notes
        node.dueDate = values.dueDate
        node.priority = values.priority
        if values.isCompleted != node.isTaskCompleted {
            if values.isCompleted {
                node.progress = 100
                node.completedAt = completionDate ?? now
                if node.marker == .task { node.marker = .done }
            } else {
                node.completedAt = nil
                if node.progress >= 100 { node.progress = 0 }
                if node.marker == .done { node.marker = .task }
            }
        }
    }

    private static func apply(_ values: AppleSyncBaseline, to reminder: EKReminder) {
        reminder.title = values.title
        reminder.notes = values.notes.isEmpty ? nil : values.notes
        reminder.priority = reminderPriority(from: values.priority)
        reminder.dueDateComponents = values.dueDate.map {
            Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0)
        }
        if reminder.isCompleted != values.isCompleted {
            reminder.isCompleted = values.isCompleted
        }
    }

    private static func sameDate(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (left?, right?): abs(left.timeIntervalSince(right)) < 60
        default: false
        }
    }

    static func taskPriority(fromReminderPriority value: Int) -> TaskPriority {
        switch value {
        case 1...4: .high
        case 5: .medium
        case 6...9: .low
        default: .none
        }
    }

    private static func sanitizedTitle(_ node: CanvasNode) -> String {
        let title = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled" : title
    }
}
