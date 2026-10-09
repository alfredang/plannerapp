import SwiftUI
import SwiftData

/// The iPhone/iPad calendar of every appointment — the same two modes as the Mac pane:
///  * **Month** — a month grid with each day's appointments written into its cell (tap a
///    day for its agenda below, swipe to change month, long-press a day to add one);
///  * **List** — every appointment in date order, grouped by day, opened at today.
/// Everyone's appointments are shown (the assignee is labelled on the row), unlike the
/// Planner's smart views which only show the owner's own queue.
struct CalendarView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    @Query(
        filter: #Predicate<PlannerItem> { $0.kindRaw == "appointment" },
        sort: \PlannerItem.date
    )
    private var allAppointments: [PlannerItem]

    @AppStorage("calendar.mode") private var modeRaw = Mode.month.rawValue
    @AppStorage("calendar.showCompleted") private var showCompleted = false
    @AppStorage(WeekStart.storageKey) private var weekStartRaw = WeekStart.defaultValue.rawValue

    @State private var month = Calendar.current.startOfMonth(for: Date())
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var editingItem: PlannerItem?
    @State private var newAppointment: NewAppointment?

    init() {
        #if DEBUG
        // Screenshot helper: `-calendarMonth 2026-11` opens the grid on that month.
        if let raw = UserDefaults.standard.string(forKey: "calendarMonth") {
            let parts = raw.split(separator: "-").compactMap { Int($0) }
            if parts.count == 2,
               let first = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)) {
                _month = State(initialValue: first)
                _selectedDay = State(initialValue: first)
            }
        }
        #endif
    }

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

    /// Taller cells on iPad, where there is room to write more of each day in.
    private var cellHeight: CGFloat { sizeClass == .regular ? 104 : 64 }

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

    var body: some View {
        let days = byDay
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $modeRaw) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                switch mode {
                case .month:
                    monthHeader
                    monthGrid(days)
                    Divider()
                    dayAgenda(days[selectedDay] ?? [])
                case .list:
                    Divider()
                    agendaList(days)
                }
            }
            .background(Theme.bg)
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Today") { goToToday() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Show Completed", isOn: $showCompleted)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Calendar options")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { addAppointment(on: selectedDay) } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add appointment")
                }
            }
            .sheet(item: $editingItem) { AddItemView(item: $0) }
            .sheet(item: $newAppointment) { new in
                AddItemView(prefill: ParsedEntry(title: "", kind: .appointment, date: new.date))
            }
        }
    }

    // MARK: - Month header

    private var monthHeader: some View {
        HStack {
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.title3.weight(.semibold))
            Spacer()
            Button { shiftMonth(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 36, height: 32)
            }
            .accessibilityLabel("Previous month")
            Button { shiftMonth(1) } label: {
                Image(systemName: "chevron.right").frame(width: 36, height: 32)
            }
            .accessibilityLabel("Next month")
        }
        .font(.body.weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private func shiftMonth(_ delta: Int) {
        guard let next = cal.date(byAdding: .month, value: delta, to: month) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { month = next }
        // Keep the agenda on a day inside the visible month.
        if !cal.isDate(selectedDay, equalTo: month, toGranularity: .month) {
            selectedDay = cal.isDate(Date(), equalTo: month, toGranularity: .month)
                ? cal.startOfDay(for: Date()) : month
        }
    }

    private func goToToday() {
        withAnimation(.easeInOut(duration: 0.2)) {
            month = cal.startOfMonth(for: Date())
            selectedDay = cal.startOfDay(for: Date())
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
        let symbols = cal.veryShortWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private func monthGrid(_ days: [Date: [PlannerItem]]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
            Divider()
            ForEach(weeks, id: \.first) { week in
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { day in
                        dayCell(day, items: days[day] ?? [])
                    }
                }
                .frame(height: cellHeight)
                Divider()
            }
        }
        .background(Color(.systemBackground))
        // Swipe left/right to change month, like the system Calendar.
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    shiftMonth(value.translation.width < 0 ? 1 : -1)
                }
        )
    }

    private func dayCell(_ day: Date, items: [PlannerItem]) -> some View {
        let inMonth = cal.isDate(day, equalTo: month, toGranularity: .month)
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
        let holiday = SingaporeHolidays.name(on: day)
        return GeometryReader { geo in
            // How many appointment lines fit under the day number (and holiday name).
            let capacity = max(0, Int((geo.size.height - 26 - (holiday == nil ? 0 : 13)) / 15))
            // Wide cells (iPad) have room for the time as well as the title.
            let showTime = geo.size.width >= 110
            let shown = items.count > capacity ? max(0, capacity - 1) : items.count
            VStack(spacing: 2) {
                Text(day.formatted(.dateTime.day()))
                    .font(.footnote.weight(isToday || isSelected ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? Color.white
                                     : (isSelected ? Theme.accent
                                        : (holiday != nil ? Color.red
                                           : (inMonth ? Color.primary : Color.secondary))))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(isToday ? Theme.accent : Color.clear))
                if let holiday {
                    Text(holiday)
                        .font(.system(size: showTime ? 11 : 8.5, weight: .semibold))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                ForEach(items.prefix(shown)) { item in
                    appointmentChip(item, showTime: showTime)
                }
                if shown < items.count {
                    Text("+\(items.count - shown)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 1.5)
            .padding(.top, 2)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .background(isSelected ? Theme.accent.opacity(0.12)
                    : (holiday != nil ? Color.red.opacity(0.06)
                       : (inMonth ? Color.clear : Color.primary.opacity(0.035))))
        .opacity(inMonth ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedDay = day
            // Tapping a spill-over day from the next/previous month moves there.
            if !inMonth { month = cal.startOfMonth(for: day) }
        }
        .contextMenu {
            Button { addAppointment(on: day) } label: {
                Label("New Appointment", systemImage: "plus")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day.formatted(date: .complete, time: .omitted))\(holiday.map { ", \($0)" } ?? ""), \(items.count) appointment\(items.count == 1 ? "" : "s")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func appointmentChip(_ item: PlannerItem, showTime: Bool) -> some View {
        HStack(spacing: 2) {
            if showTime, let label = Self.timeLabel(item.date) {
                Text(label)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .fixedSize()
            }
            Text(item.title)
                .strikethrough(item.isDone)
        }
        .font(.system(size: showTime ? 11 : 9.5))
        .lineLimit(1)
        .foregroundStyle(item.isDone ? Color.secondary : Color.primary)
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 3)
            .fill(Theme.accent.opacity(item.isDone ? 0.07 : 0.2)))
    }

    // MARK: - Selected-day agenda

    private func dayAgenda(_ items: [PlannerItem]) -> some View {
        List {
            Section {
                if items.isEmpty {
                    Button {
                        addAppointment(on: selectedDay)
                    } label: {
                        Label("No appointments — tap to add one", systemImage: "plus.circle")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(items) { row($0) }
                }
            } header: {
                HStack {
                    Text(DaySections.title(for: selectedDay))
                    if let holiday = SingaporeHolidays.name(on: selectedDay) {
                        Spacer()
                        Label(holiday, systemImage: "flag.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func row(_ item: PlannerItem) -> some View {
        ItemRow(item: item) {
            withAnimation { item.toggleDone() }
        } onEdit: {
            editingItem = item
        }
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
                    Text("No appointments yet. Tap + to add one, or tell the assistant on the Planner tab.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sortedDays, id: \.self) { day in
                    Section {
                        ForEach(days[day] ?? []) { row($0) }
                    } header: {
                        HStack {
                            Text(DaySections.title(for: day))
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
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .onAppear {
                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
            }
        }
    }

    // MARK: - Formatting

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
    CalendarView()
        .modelContainer(for: PlannerItem.self, inMemory: true)
}
