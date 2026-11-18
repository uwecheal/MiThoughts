import SwiftUI

// MARK: - Task semantics

enum DueStatus: Int, Comparable {
    case overdue, today, soon, later, none

    static func < (lhs: DueStatus, rhs: DueStatus) -> Bool { lhs.rawValue < rhs.rawValue }

    var color: Color {
        switch self {
        case .overdue: .red
        case .today: .orange
        case .soon: .yellow
        case .later, .none: .secondary
        }
    }
}

extension CanvasNode {
    var isTaskCompleted: Bool { completedAt != nil || progress >= 100 }

    /// A topic counts as a task once it carries any task information (like iThoughts' task list).
    var isTask: Bool {
        progress > 0 || completedAt != nil || dueDate != nil || startDate != nil || priority != .none
            || !resources.isEmpty || effort > 0 || marker == .task || marker == .done
            || appleReminderID != nil || appleCalendarEventID != nil
    }

    func dueStatus(now: Date = Date(), calendar: Calendar = .current) -> DueStatus {
        guard let dueDate, !isTaskCompleted else {
            return .none
        }
        if calendar.isDate(dueDate, inSameDayAs: now) {
            return dueDate < now && calendar.component(.hour, from: dueDate) != 0 ? .overdue : .today
        }
        if dueDate < now {
            return .overdue
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: dueDate)).day ?? 99
        return days <= 7 ? .soon : .later
    }
}

extension TaskPriority {
    var symbol: String {
        switch self {
        case .none: ""
        case .low: "!"
        case .medium: "!!"
        case .high: "!!!"
        }
    }

    var color: Color {
        switch self {
        case .none: .secondary
        case .low: .blue
        case .medium: .orange
        case .high: .red
        }
    }

    var rank: Int {
        switch self {
        case .high: 0
        case .medium: 1
        case .low: 2
        case .none: 3
        }
    }
}

// MARK: - Quick actions

enum TaskAction: Equatable {
    case toggleDone
    case setProgress(Int)
    case stepProgress(Int)
    case setPriority(TaskPriority)
    case dueToday
    case dueTomorrow
    case dueNextWeek
    case clearDates
    case toggleResource(String)
    case clearResources

    /// Applies the action to one topic. Pure, so it is easy to test and to undo.
    static func apply(_ action: TaskAction, to node: inout CanvasNode, now: Date = Date(), calendar: Calendar = .current) {
        func endOfWorkday(daysFromNow days: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day) ?? day
        }
        func setProgress(_ value: Int) {
            node.progress = min(max(value, 0), 100)
            if node.progress >= 100 {
                node.completedAt = node.completedAt ?? now
            } else {
                node.completedAt = nil
            }
        }

        switch action {
        case .toggleDone:
            if node.isTaskCompleted {
                node.completedAt = nil
                if node.progress >= 100 {
                    node.progress = 0
                }
                if node.marker == .done {
                    node.marker = .task
                }
            } else {
                node.progress = 100
                node.completedAt = now
                if node.marker == .task {
                    node.marker = .done
                }
            }
        case let .setProgress(value):
            setProgress(value)
        case let .stepProgress(step):
            // Move to the next/previous multiple of 25 (e.g. 30% -> 50% or 25%).
            let current = node.isTaskCompleted ? 100 : node.progress
            if step > 0 {
                setProgress((current / 25 + 1) * 25)
            } else {
                setProgress(current % 25 == 0 ? current - 25 : (current / 25) * 25)
            }
        case let .setPriority(priority):
            node.priority = priority
        case .dueToday:
            node.dueDate = endOfWorkday(daysFromNow: 0)
        case .dueTomorrow:
            node.dueDate = endOfWorkday(daysFromNow: 1)
        case .dueNextWeek:
            // Next Monday, like iThoughts' "next week".
            let weekday = calendar.component(.weekday, from: now)
            let daysToMonday = (9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7
            node.dueDate = endOfWorkday(daysFromNow: daysToMonday)
        case .clearDates:
            node.startDate = nil
            node.dueDate = nil
        case let .toggleResource(name):
            if let index = node.resources.firstIndex(of: name) {
                node.resources.remove(at: index)
            } else {
                node.resources.append(name)
            }
        case .clearResources:
            node.resources = []
        }
    }
}

enum TaskCommand {
    /// object: TaskAction
    static let perform = Notification.Name("TaskCommand.perform")
    static let toggleTaskList = Notification.Name("TaskCommand.toggleTaskList")
    static let syncApple = Notification.Name("TaskCommand.syncApple")
    static let toggleHideCompleted = Notification.Name("TaskCommand.toggleHideCompleted")

    static func post(_ action: TaskAction) {
        NotificationCenter.default.post(name: perform, object: action)
    }
}

/// The Task menu used in the menu bar and in the topic context menu.
struct TaskActionMenuItems: View {
    var knownResources: [String] = []
    var assignedResources: [String] = []
    var isCompleted = false
    var showsShortcuts = false
    let perform: (TaskAction) -> Void

    var body: some View {
        Button(isCompleted ? "Mark as Not Done" : "Mark as Done") { perform(.toggleDone) }
            .shortcut(showsShortcuts, "d", [.command, .control])

        Menu("Progress") {
            ForEach([0, 25, 50, 75, 100], id: \.self) { value in
                Button("\(value)%") { perform(.setProgress(value)) }
            }
            Divider()
            Button("Increase 25%") { perform(.stepProgress(25)) }
                .shortcut(showsShortcuts, "=", [.command, .control])
            Button("Decrease 25%") { perform(.stepProgress(-25)) }
                .shortcut(showsShortcuts, "-", [.command, .control])
        }

        // iThoughts: ⌘1 … ⌘5 set priority (1 = highest).
        Menu("Priority") {
            Button("High") { perform(.setPriority(.high)) }
                .shortcut(showsShortcuts, "1", [.command])
            Button("Medium") { perform(.setPriority(.medium)) }
                .shortcut(showsShortcuts, "2", [.command])
            Button("Low") { perform(.setPriority(.low)) }
                .shortcut(showsShortcuts, "3", [.command])
            Button("None") { perform(.setPriority(.none)) }
        }

        Menu("Due Date") {
            Button("Today") { perform(.dueToday) }
            Button("Tomorrow") { perform(.dueTomorrow) }
            Button("Next Week") { perform(.dueNextWeek) }
            Divider()
            Button("Clear Dates") { perform(.clearDates) }
        }

        Menu("Resources") {
            if knownResources.isEmpty {
                Text("Add resources in Edit Details")
            }
            ForEach(knownResources, id: \.self) { name in
                Button {
                    perform(.toggleResource(name))
                } label: {
                    if assignedResources.contains(name) {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
            if !assignedResources.isEmpty {
                Divider()
                Button("Clear Resources") { perform(.clearResources) }
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func shortcut(_ enabled: Bool, _ key: Character, _ modifiers: EventModifiers) -> some View {
        if enabled {
            keyboardShortcut(KeyEquivalent(key), modifiers: modifiers)
        } else {
            self
        }
    }
}

// MARK: - Canvas badges

/// Compact task status under a topic title: progress ring, due date, priority, resources.
struct TaskBadgeRow: View {
    var progress: Int?
    var dueText: String?
    var dueStatus: DueStatus
    var priority: TaskPriority
    var resources: [String]
    var scale: CGFloat
    var textColor: Color

    var body: some View {
        HStack(spacing: 5 * scale) {
            if let progress {
                ZStack {
                    Circle().stroke(textColor.opacity(0.2), lineWidth: 2 * scale)
                    Circle()
                        .trim(from: 0, to: CGFloat(progress) / 100)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 10 * scale, height: 10 * scale)
                Text("\(progress)%")
                    .foregroundStyle(textColor.opacity(0.7))
            }
            if let dueText {
                Text(dueText)
                    .padding(.horizontal, 4 * scale)
                    .background(dueStatus.color.opacity(dueStatus <= .soon ? 0.22 : 0.0), in: Capsule())
                    .foregroundStyle(dueStatus <= .today ? dueStatus.color : textColor.opacity(0.7))
            }
            if priority != .none {
                Text(priority.symbol)
                    .fontWeight(.heavy)
                    .foregroundStyle(priority.color)
            }
            if !resources.isEmpty {
                Text("@" + resources.joined(separator: ", "))
                    .foregroundStyle(textColor.opacity(0.7))
            }
        }
        .font(.system(size: 9.5 * scale, weight: .semibold))
        .lineLimit(1)
    }
}

// MARK: - Task list

enum TaskDateFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case overdue = "Overdue"
    case today = "Today"
    case week = "7 Days"
    case undated = "No Date"

    var id: String { rawValue }
}

enum TaskSortOrder: String, CaseIterable, Identifiable {
    case due = "Due Date"
    case priority = "Priority"
    case map = "Map Order"

    var id: String { rawValue }
}

struct TaskListItem: Identifiable {
    var node: CanvasNode
    var path: String
    var mapOrder: Int
    var id: UUID { node.id }
}

enum TaskListBuilder {
    static let unassigned = "—"

    /// Tasks in map (pre-)order with their breadcrumb.
    static func items(from nodes: [CanvasNode]) -> [TaskListItem] {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let children = Dictionary(grouping: nodes.filter { $0.parentID != nil }) { $0.parentID! }
            .mapValues { $0.sorted { $0.sortIndex == $1.sortIndex ? $0.y < $1.y : $0.sortIndex < $1.sortIndex } }
        let roots = nodes.filter { $0.parentID.map { byID[$0] == nil } ?? true }.sorted { $0.sortIndex < $1.sortIndex }
        var result: [TaskListItem] = []
        var visited = Set<UUID>()
        func visit(_ node: CanvasNode, path: [String]) {
            guard !visited.contains(node.id) else {
                return
            }
            visited.insert(node.id)
            let title = TopicText.plain(node.title).components(separatedBy: "\n").first ?? ""
            if node.isTask {
                result.append(TaskListItem(node: node, path: path.suffix(2).joined(separator: " › "), mapOrder: result.count))
            }
            for child in children[node.id] ?? [] {
                visit(child, path: path + [title])
            }
        }
        roots.forEach { visit($0, path: []) }
        return result
    }

    static func filter(
        _ items: [TaskListItem],
        date: TaskDateFilter,
        resource: String?,
        showCompleted: Bool,
        sort: TaskSortOrder,
        now: Date = Date()
    ) -> [TaskListItem] {
        let filtered = items.filter { item in
            let node = item.node
            if !showCompleted && node.isTaskCompleted {
                return false
            }
            if let resource {
                if resource == unassigned ? !node.resources.isEmpty : !node.resources.contains(resource) {
                    return false
                }
            }
            let status = node.dueStatus(now: now)
            switch date {
            case .all: return true
            case .overdue: return status == .overdue
            case .today: return status == .overdue || status == .today
            case .week: return status != .none && status != .later
            case .undated: return node.dueDate == nil
            }
        }
        switch sort {
        case .map:
            return filtered
        case .priority:
            return filtered.sorted {
                ($0.node.priority.rank, $0.node.dueDate ?? .distantFuture, $0.mapOrder)
                    < ($1.node.priority.rank, $1.node.dueDate ?? .distantFuture, $1.mapOrder)
            }
        case .due:
            return filtered.sorted {
                ($0.node.isTaskCompleted ? 1 : 0, $0.node.dueDate ?? .distantFuture, $0.node.priority.rank, $0.mapOrder)
                    < ($1.node.isTaskCompleted ? 1 : 0, $1.node.dueDate ?? .distantFuture, $1.node.priority.rank, $1.mapOrder)
            }
        }
    }
}

struct TaskListPanelView: View {
    let nodes: [CanvasNode]
    let isSyncing: Bool
    let lastSyncText: String?
    let onJump: (UUID) -> Void
    let onToggleDone: (UUID) -> Void
    let onAddToReminders: ([UUID]) -> Void
    let onSync: () -> Void
    let onClose: () -> Void

    @AppStorage("TaskList.dateFilter") private var dateFilter: TaskDateFilter = .all
    @AppStorage("TaskList.sort") private var sort: TaskSortOrder = .due
    @AppStorage("TaskList.showCompleted") private var showCompleted = false
    @State private var resource: String?

    private var allItems: [TaskListItem] { TaskListBuilder.items(from: nodes) }

    private var resourceNames: [String] {
        Array(Set(nodes.flatMap(\.resources))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        let all = allItems
        let items = TaskListBuilder.filter(all, date: dateFilter, resource: resource, showCompleted: showCompleted, sort: sort)
        let open = all.filter { !$0.node.isTaskCompleted }
        let overdue = open.filter { $0.node.dueStatus() == .overdue }.count
        let dueToday = open.filter { $0.node.dueStatus() == .today }.count
        let done = all.count - open.count
        let withoutReminder = items.filter { !$0.node.isTaskCompleted && $0.node.appleReminderID == nil }.map(\.id)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tasks").font(.headline)
                Text("\(open.count) open · \(done) done").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close (⌥⌘T)")
            }

            if !all.isEmpty {
                ProgressView(value: Double(done), total: Double(max(all.count, 1)))
                    .help("\(done) of \(all.count) tasks done")
            }

            Picker("Show", selection: $dateFilter) {
                ForEach(TaskDateFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Picker("Resource", selection: $resource) {
                    Text("Everyone").tag(String?.none)
                    Text("Unassigned").tag(String?.some(TaskListBuilder.unassigned))
                    if !resourceNames.isEmpty {
                        Divider()
                    }
                    ForEach(resourceNames, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                .frame(maxWidth: 170)
                Picker("Sort", selection: $sort) {
                    ForEach(TaskSortOrder.allCases) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .frame(maxWidth: 160)
                Toggle("Completed", isOn: $showCompleted)
                    .toggleStyle(.checkbox)
            }
            .controlSize(.small)

            if overdue + dueToday > 0 {
                HStack(spacing: 10) {
                    if overdue > 0 {
                        Label("\(overdue) overdue", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                    }
                    if dueToday > 0 {
                        Label("\(dueToday) due today", systemImage: "clock.fill").foregroundStyle(.orange)
                    }
                }
                .font(.caption.weight(.medium))
            }

            if items.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "checklist").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(all.isEmpty ? "No tasks yet. Give a topic a due date, priority, progress or resource (right-click ▸ Task)." : "No tasks match these filters.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(items) { item in
                    TaskRow(item: item, onToggleDone: { onToggleDone(item.id) })
                        .contentShape(Rectangle())
                        .onTapGesture { onJump(item.id) }
                }
                .listStyle(.inset)
            }

            HStack {
                Button {
                    onSync()
                } label: {
                    Label(isSyncing ? "Syncing..." : "Sync Reminders & Calendar", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isSyncing)
                if let lastSyncText {
                    Text(lastSyncText).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add \(withoutReminder.count) to Reminders") {
                    onAddToReminders(withoutReminder)
                }
                .disabled(withoutReminder.isEmpty || isSyncing)
                .help("Create Apple Reminders for the open tasks shown that are not linked yet")
            }
            .controlSize(.small)
        }
        .padding(16)
    }
}

private struct TaskRow: View {
    let item: TaskListItem
    let onToggleDone: () -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d HH:mm")
        return formatter
    }()

    var body: some View {
        let node = item.node
        let status = node.dueStatus()
        HStack(alignment: .top, spacing: 8) {
            Button(action: onToggleDone) {
                Image(systemName: node.isTaskCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(node.isTaskCompleted ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(node.isTaskCompleted ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if node.priority != .none {
                        Text(node.priority.symbol).fontWeight(.heavy).foregroundStyle(node.priority.color)
                    }
                    Text(TopicText.plain(node.title).components(separatedBy: "\n").first ?? "")
                        .strikethrough(node.isTaskCompleted)
                        .foregroundStyle(node.isTaskCompleted ? .secondary : .primary)
                        .lineLimit(1)
                    if node.appleReminderID != nil {
                        Image(systemName: "checklist").font(.caption2).foregroundStyle(.secondary).help("Linked to Apple Reminders")
                    }
                    if node.appleCalendarEventID != nil {
                        Image(systemName: "calendar").font(.caption2).foregroundStyle(.secondary).help("Linked to Apple Calendar")
                    }
                }
                HStack(spacing: 8) {
                    if !item.path.isEmpty {
                        Text(item.path).lineLimit(1)
                    }
                    if let due = node.dueDate {
                        Text(Self.dateFormatter.string(from: due))
                            .foregroundStyle(status <= .today ? status.color : .secondary)
                    }
                    if !node.resources.isEmpty {
                        Text("@" + node.resources.joined(separator: ", ")).lineLimit(1)
                    }
                    if node.progress > 0 && !node.isTaskCompleted {
                        Text("\(node.progress)%")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
