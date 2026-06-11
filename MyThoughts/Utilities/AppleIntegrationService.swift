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

    private static func reminderPriority(from priority: TaskPriority) -> Int {
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

    private static func validEndDate(from dueDate: Date?, after startDate: Date) -> Date {
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
