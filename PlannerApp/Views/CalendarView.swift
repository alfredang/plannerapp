import SwiftUI
import SwiftData

/// Built-in calendar. A graphical month calendar with a dot on days that have appointments,
/// plus the list of appointments for the selected day.
struct CalendarView: View {
    @Environment(\.modelContext) private var context

    @Query(
        filter: #Predicate<PlannerItem> { $0.kindRaw == "appointment" && !$0.isArchived },
        sort: \PlannerItem.date
    )
    private var appointments: [PlannerItem]

    @State private var selectedDate = Date()
    @State private var editingItem: PlannerItem?

    private var cal: Calendar { Calendar.current }

    private var appointmentsOnSelectedDay: [PlannerItem] {
        appointments
            .filter { item in
                guard let d = item.date else { return false }
                return cal.isDate(d, inSameDayAs: selectedDate)
            }
            .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    private var datesWithAppointments: Set<DateComponents> {
        Set(appointments.compactMap { item in
            item.date.map { cal.dateComponents([.year, .month, .day], from: $0) }
        })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DatePicker("Date", selection: $selectedDate, displayedComponents: [.date])
                        .datePickerStyle(.graphical)
                        .tint(Theme.accent)
                }

                Section(selectedDayTitle) {
                    if appointmentsOnSelectedDay.isEmpty {
                        Text("No appointments on this day.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appointmentsOnSelectedDay) { item in
                            ItemRow(item: item) {
                                withAnimation { item.toggleDone() }
                            } onEdit: {
                                editingItem = item
                            }
                        }
                    }
                }

                if !upcoming.isEmpty {
                    Section("Upcoming") {
                        ForEach(upcoming) { item in
                            ItemRow(item: item) {
                                withAnimation { item.toggleDone() }
                            } onEdit: {
                                editingItem = item
                            }
                        }
                    }
                }
            }
            .navigationTitle("Calendar")
            .sheet(item: $editingItem) { AddItemView(item: $0) }
        }
    }

    private var selectedDayTitle: String {
        selectedDate.formatted(.dateTime.weekday(.wide).month().day())
    }

    private var upcoming: [PlannerItem] {
        let now = Date()
        return appointments
            .filter { ($0.date ?? .distantPast) >= now && !cal.isDate($0.date ?? now, inSameDayAs: selectedDate) }
            .prefix(5)
            .map { $0 }
    }
}

#Preview {
    CalendarView()
        .modelContainer(for: PlannerItem.self, inMemory: true)
}
