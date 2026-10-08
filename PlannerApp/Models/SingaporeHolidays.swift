import Foundation

/// Singapore public holidays, as gazetted by the Ministry of Manpower
/// (https://www.mom.gov.sg/employment-practices/public-holidays). Bundled rather than
/// fetched so the calendar works offline; add the next year's list when MOM publishes it
/// (usually mid-year). A holiday falling on a Sunday makes the Monday a holiday too — those
/// are listed as "(observed)".
enum SingaporeHolidays {
    struct Holiday {
        let day: Date      // start of the day, in the user's calendar
        let name: String
    }

    /// yyyy-MM-dd → name.
    private static let table: [(String, String)] = [
        // 2025
        ("2025-01-01", "New Year's Day"),
        ("2025-01-29", "Chinese New Year"),
        ("2025-01-30", "Chinese New Year"),
        ("2025-03-31", "Hari Raya Puasa"),
        ("2025-04-18", "Good Friday"),
        ("2025-05-01", "Labour Day"),
        ("2025-05-03", "Polling Day"),
        ("2025-05-12", "Vesak Day"),
        ("2025-06-07", "Hari Raya Haji"),
        ("2025-08-09", "National Day"),
        ("2025-10-20", "Deepavali"),
        ("2025-12-25", "Christmas Day"),
        // 2026
        ("2026-01-01", "New Year's Day"),
        ("2026-02-17", "Chinese New Year"),
        ("2026-02-18", "Chinese New Year"),
        ("2026-03-21", "Hari Raya Puasa"),
        ("2026-04-03", "Good Friday"),
        ("2026-05-01", "Labour Day"),
        ("2026-05-27", "Hari Raya Haji"),
        ("2026-05-31", "Vesak Day"),
        ("2026-06-01", "Vesak Day (observed)"),
        ("2026-08-09", "National Day"),
        ("2026-08-10", "National Day (observed)"),
        ("2026-11-08", "Deepavali"),
        ("2026-11-09", "Deepavali (observed)"),
        ("2026-12-25", "Christmas Day"),
        // 2027
        ("2027-01-01", "New Year's Day"),
        ("2027-02-06", "Chinese New Year"),
        ("2027-02-07", "Chinese New Year"),
        ("2027-02-08", "Chinese New Year (observed)"),
        ("2027-03-10", "Hari Raya Puasa"),
        ("2027-03-26", "Good Friday"),
        ("2027-05-01", "Labour Day"),
        ("2027-05-17", "Hari Raya Haji"),
        ("2027-05-20", "Vesak Day"),
        ("2027-08-09", "National Day"),
        ("2027-10-28", "Deepavali"),
        ("2027-12-25", "Christmas Day"),
    ]

    /// Holidays keyed by the start of their day in the current calendar.
    static let byDay: [Date: String] = {
        let cal = Calendar.current
        var result: [Date: String] = [:]
        for (stamp, name) in table {
            let parts = stamp.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let date = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
            else { continue }
            result[cal.startOfDay(for: date)] = name
        }
        return result
    }()

    /// The holiday on `date`'s day, if any.
    static func name(on date: Date) -> String? {
        byDay[Calendar.current.startOfDay(for: date)]
    }
}
