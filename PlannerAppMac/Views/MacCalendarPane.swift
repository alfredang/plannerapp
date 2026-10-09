import SwiftUI
import SwiftData

/// Desktop calendar of every appointment. Two modes:
///  * **Month** — a month grid with each day's appointments written into its cell (click a
///    day for its agenda below, double-click to add one, click an appointment to edit it);
///  * **List** — every appointment in date order, grouped by day, opened at today.
/// Everyone's appointments are shown (the assignee is labelled), unlike the smart views
/// which only show the owner's own queue. Completed appointments can be shown dimmed.
struct MacCalendarPane: View {
    @Query(
        filter: #Predicate<PlannerItem> { $0.kindRaw == "appointment" },
        sort: \PlannerItem.date
    )
    private var allAppointments: [PlannerItem]

    @AppStorage("calendar.mode") private var modeRaw = Mode.month.rawValue
    @AppStorage("calendar.showCompleted") private var showCompleted = true
    @AppStorage(WeekStart.storageKey) private var weekStartRaw = WeekStart.defaultValue.rawValue

    @State private var month = Calendar.current.startOfMonth(for: Date())
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var editingItem: PlannerItem?
    @State private var newAppointment: NewAppointment?

    private enum Mode: String, CaseIterable, Identifiable {
        case month, list
        var id: String { rawValue }
        var title: String { self == .month ? "Month" : "List" }
    }

    /// Identifiable wrapper so the add sheet can be presented with its day.
    private struct NewAppointment: Identifiable {
        let id = UUID()
        let date: Date
    }

    private var mode: Mode { Mode(rawValue: modeRaw) ?? .month }
    private var cal: Calendar { (WeekStart(rawValue: weekStartRaw) ?? .defaultValue).calendar }

    /// Dated appointments to show. Archived ones only when they were completed (and the
    /// toggle is on) — archived-but-not-done means removed (e.g. a duplicate), so never.
    private var appointments: [PlannerItem] {
        allAppointments.filter { item in
            guard item.date != nil else { return false }
            return !item.isArchived || (showCompleted && item.isDone)
        }
    }

    /// Appointments keyed by the start of their day, each day in time order.
    private var byDay: [Date: [PlannerItem]] {
        Dictionary(grouping: appointments) { cal.startOfDay(for: $0.date ?? .distantPast) }
    }

    private var upcomingCount: Int {
        let start = cal.startOfDay(for: Date())
        return appointments.filter { !$0.isArchived && ($0.date ?? .distantPast) >= start }.count
    }

    var body: some View {
        let days = byDay
        VStack(spacing: 0) {
            header
            Divider()
            switch mode {
            case .month:
                VSplitView {
                    monthGrid(days)
                        .frame(minHeight: 300)
                    dayAgenda(days[selectedDay] ?? [])
                        .frame(minHeight: 110, idealHeight: 190)
                }
            case .list:
                agendaList(days)
            }
        }
        .navigationTitle("Calendar")
        .navigationSubtitle("\(upcomingCount) upcoming appointment\(upcomingCount == 1 ? "" : "s")")
        .sheet(item: $editingItem) { AddItemView(item: $0) }
        .sheet(item: $newAppointment) { new in
            AddItemView(prefill: ParsedEntry(title: "", kind: .appointment, date: new.date))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            if mode == .month {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Text("All Appointments")
                    .font(.title2.weight(.semibold))
            }
            Spacer(minLength: 8)
            Toggle("Show completed", isOn: $showCompleted)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Include appointments that were checked off (they are archived)")
            Picker("View", selection: $modeRaw) {
                ForEach(Mode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if mode == .month {
                ControlGroup {
                    Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                        .help("Previous month")
                        .accessibilityLabel("Previous month")
                    Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                        .help("Next month")
                        .accessibilityLabel("Next month")
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func shiftMonth(_ delta: Int) {
        guard let next = cal.date(byAdding: .month, value: delta, to: month) else { return }
        month = next
        // Keep the agenda on a day inside the visible month.
        if !cal.isDate(selectedDay, equalTo: month, toGranularity: .month) {
            selectedDay = cal.isDate(Date(), equalTo: month, toGranularity: .month)
                ? cal.startOfDay(for: Date()) : month
        }
    }

    // MARK: - Month grid

    /// The weeks shown for `month`: whole weeks from the one containing the 1st through the
    /// one containing the last day, honouring the locale's first weekday.
    private var weeks: [[Date]] {
        guard let range = cal.range(of: .day, in: .month, for: month),
              let lastDay = cal.date(byAdding: .day, value: range.count - 1, to: month) else { return [] }
        let leading = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        guard var day = cal.date(byAdding: .day, value: -leading, to: month) else { return [] }
        var result: [[Date]] = []
        while day <= lastDay {
            var week: [Date] = []
            for _ in 0..<7 {
                week.append(day)
                day = cal.date(byAdding: .day, value: 1, to: day) ?? day
            }
            result.append(week)
        }
        return result
    }

    private var weekdaySymbols: [String] {
        let symbols = cal.shortWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private func monthGrid(_ days: [Date: [PlannerItem]]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 6)
            Divider()
            ForEach(weeks, id: \.first) { week in
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { day in
                        dayCell(day, items: days[day] ?? [])
                        if day != week.last { Divider() }
                    }
                }
                .frame(maxHeight: .infinity)
                Divider()
            }
        }
    }

    private func dayCell(_ day: Date, items: [PlannerItem]) -> some View {
        let inMonth = cal.isDate(day, equalTo: month, toGranularity: .month)
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
        let holiday = SingaporeHolidays.name(on: day)
        return GeometryReader { geo in
            // How many appointment lines fit under the day number (and holiday name).
            let capacity = max(0, Int((geo.size.height - 24 - (holiday == nil ? 0 : 16)) / 16))
            // Narrow cells (the agent panel open) keep the title and drop the time.
            let showTime = geo.size.width >= 120
            let shown = items.count > capacity ? max(0, capacity - 1) : items.count
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Spacer(minLength: 0)
                    Text(day.formatted(.dateTime.day()))
                        .font(.callout.weight(isToday ? .bold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(isToday ? Color.white
                                         : (holiday != nil ? Color.red
                                            : (inMonth ? Color.primary : Color.secondary)))
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Circle().fill(isToday ? Theme.accent : Color.clear))
                }
                if let holiday {
                    Text(holiday)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .padding(.leading, 4)
                        .help("Singapore public holiday: \(holiday)")
                }
                ForEach(items.prefix(shown)) { item in
                    appointmentChip(item, showTime: showTime)
                }
                if shown < items.count {
                    Text("+\(items.count - shown) more")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(4)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isSelected ? Theme.accent.opacity(0.12)
                    : (holiday != nil ? Color.red.opacity(0.06)
                       : (inMonth ? Color.clear : Color.primary.opacity(0.035))))
        .opacity(inMonth ? 1 : 0.6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { addAppointment(on: day) }
        .onTapGesture { selectedDay = day }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(day.formatted(date: .complete, time: .omitted))\(holiday.map { ", \($0)" } ?? ""), \(items.count) appointment\(items.count == 1 ? "" : "s")")
    }

    private func appointmentChip(_ item: PlannerItem, showTime: Bool) -> some View {
        HStack(spacing: 3) {
            if showTime, let label = Self.timeLabel(item.date) {
                Text(label)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .fixedSize()
            }
            Text(item.title)
                .strikethrough(item.isDone)
                .layoutPriority(1)
        }
        .font(.caption)
        .lineLimit(1)
        .foregroundStyle(item.isDone ? Color.secondary : Color.primary)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(Theme.accent.opacity(item.isDone ? 0.07 : 0.2)))
        .contentShape(Rectangle())
        .onTapGesture { editingItem = item }
        .help(chipHelp(item))
        .contextMenu { itemMenu(item) }
    }

    private func chipHelp(_ item: PlannerItem) -> String {
        var parts = [item.title]
        if let date = item.date { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if !item.assignedTo.isEmpty { parts.append("Assigned to \(item.assignedTo)") }
        if let list = item.list?.name { parts.append("List: \(list)") }
        return parts.joined(separator: "\n")
    }

    @ViewBuilder
    private func itemMenu(_ item: PlannerItem) -> some View {
        Button("Edit…") { editingItem = item }
        Button(item.isDone ? "Mark as Not Done" : "Mark as Done") {
            withAnimation { item.toggleDone() }
        }
    }

    // MARK: - Selected-day agenda

    private func dayAgenda(_ items: [PlannerItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(dayTitle(selectedDay))
                    .font(.headline)
                if let holiday = SingaporeHolidays.name(on: selectedDay) {
                    Label(holiday, systemImage: "flag.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                }
                Spacer()
                Button {
                    addAppointment(on: selectedDay)
                } label: {
                    Label("Add Appointment", systemImage: "plus")
                }
                .help("New appointment on this day (or double-click a day)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            if items.isEmpty {
                Text("No appointments on this day.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(items) { item in
                        row(item)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func row(_ item: PlannerItem) -> some View {
        ItemRow(item: item) {
            withAnimation { item.toggleDone() }
        } onEdit: {
            editingItem = item
        }
        .contextMenu { itemMenu(item) }
    }

    private func addAppointment(on day: Date) {
        selectedDay = cal.startOfDay(for: day)
        // New appointments default to 9:00 on the chosen day.
        let start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        newAppointment = NewAppointment(date: start)
    }

    // MARK: - List mode

    private func agendaList(_ days: [Date: [PlannerItem]]) -> some View {
        let sortedDays = days.keys.sorted()
        let today = cal.startOfDay(for: Date())
        let anchor = sortedDays.first { $0 >= today } ?? sortedDays.last
        return ScrollViewReader { proxy in
            List {
                if sortedDays.isEmpty {
                    Text("No appointments yet. Ask the agent, or use + in the toolbar.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sortedDays, id: \.self) { day in
                    Section {
                        ForEach(days[day] ?? []) { item in
                            row(item)
                        }
                    } header: {
                        HStack {
                            Text(dayTitle(day))
                            if let holiday = SingaporeHolidays.name(on: day) {
                                Text(holiday).foregroundStyle(.red)
                            }
                            if day < today {
                                Text("Past").foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .id(day)
                }
            }
            .listStyle(.inset)
            .onAppear {
                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
            }
        }
    }

    // MARK: - Formatting

    private func dayTitle(_ day: Date) -> String {
        let full = day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        if cal.isDateInToday(day) { return "Today · \(full)" }
        if cal.isDateInTomorrow(day) { return "Tomorrow · \(full)" }
        if cal.isDateInYesterday(day) { return "Yesterday · \(full)" }
        let year = cal.component(.year, from: day)
        return year == cal.component(.year, from: Date()) ? full : "\(full) \(year)"
    }

    /// "9:00" style label, or nil for date-only appointments (stored at midnight).
    private static func timeLabel(_ date: Date?) -> String? {
        guard let date else { return nil }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        if parts.hour == 0 && parts.minute == 0 { return nil }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

private extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? startOfDay(for: date)
    }
}

#Preview {
    MacCalendarPane()
        .modelContainer(for: PlannerItem.self, inMemory: true)
        .frame(width: 800, height: 640)
}
