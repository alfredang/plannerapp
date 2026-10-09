import SwiftUI
import AppKit

/// One scheduled background job, from whichever system runs it.
struct ScheduledJob: Identifiable {
    enum Source: String, CaseIterable {
        case workforce = "Digital Workforce"
        case hermes = "Hermes"
        case openclaw = "OpenClaw"
        case planner = "Planner"

        var symbol: String {
            switch self {
            case .workforce: return "person.3.fill"
            case .hermes:    return "bolt.horizontal.circle.fill"
            case .openclaw:  return "pawprint.fill"
            case .planner:   return "bell.badge.fill"
            }
        }
    }

    enum Status { case ok, failed, skipped, unknown }

    var id: String
    var source: Source
    var name: String
    var detail: String?        // agent, delivery target…
    var schedule: String       // human-readable
    var nextRun: Date?
    var lastRun: Date?
    var status: Status
    var lastError: String?
    var enabled: Bool
    var logURL: URL?
    var launchdLabel: String?  // Digital Workforce jobs can be started now via launchctl
}

/// Reads every scheduler on this Mac: the Digital Workforce LaunchAgents
/// (`~/Library/LaunchAgents/com.alfred.workforce.*`), Hermes cron (`~/.hermes/cron/jobs.json`),
/// OpenClaw cron (`openclaw cron list --json`) and Planner's own WhatsApp reminders.
/// Read-only apart from "Run Now".
enum ScheduleLoader {
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    static let workforcePrefix = "com.alfred.workforce."
    private static var workforceLogs: URL { home.appendingPathComponent("DigitalWorkforce/logs") }

    static func loadAll() -> [ScheduledJob] {
        workforce() + hermes() + openclaw() + planner()
    }

    // MARK: Digital Workforce (launchd)

    private static func workforce() -> [ScheduledJob] {
        let dir = home.appendingPathComponent("Library/LaunchAgents")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(workforcePrefix) && $0.pathExtension == "plist" }
        let exitCodes = launchctlExitCodes()
        let logs = (try? FileManager.default.contentsOfDirectory(
            at: workforceLogs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []

        return files.compactMap { url -> ScheduledJob? in
            guard let plist = NSDictionary(contentsOf: url) as? [String: Any],
                  let label = plist["Label"] as? String else { return nil }
            let args = plist["ProgramArguments"] as? [String] ?? []
            let short = String(label.dropFirst(workforcePrefix.count))
            // run-agent.sh <agent> <job>
            var agent: String?
            if let i = args.firstIndex(where: { $0.hasSuffix("run-agent.sh") }), args.count > i + 2 {
                agent = args[i + 1].capitalized
            }
            var schedule = "On demand"
            var next: Date?
            if let interval = plist["StartCalendarInterval"] {
                let entries = (interval as? [[String: Int]]) ?? [(interval as? [String: Int]) ?? [:]]
                schedule = entries.map(describe).joined(separator: ", ")
                next = entries.compactMap(nextDate).min()
            } else if let seconds = plist["StartInterval"] as? Int {
                schedule = seconds % 60 == 0 ? "Every \(seconds / 60) min" : "Every \(seconds) s"
            }
            // Latest per-run log: logs/<yyyy-MM-dd>-<agent>-<job>.log
            let jobName = args.last ?? short
            let log = logs.filter { $0.lastPathComponent.hasSuffix("-\(jobName).log") }
                .max { modified($0) < modified($1) }
            let code = exitCodes[label]
            let status: ScheduledJob.Status = code == nil ? .unknown : (code == 0 ? .ok : .failed)
            return ScheduledJob(
                id: "wf-" + label, source: .workforce,
                name: short.replacingOccurrences(of: "-", with: " ").capitalized,
                detail: agent, schedule: schedule, nextRun: next,
                lastRun: log.map(modified), status: log == nil && code == 0 ? .unknown : status,
                lastError: code.flatMap { $0 == 0 ? nil : "Last exit code \($0)" },
                enabled: true, logURL: log, launchdLabel: label)
        }
    }

    /// `launchctl list` → label: last exit status.
    private static func launchctlExitCodes() -> [String: Int] {
        guard let out = run("/bin/launchctl", ["list"]) else { return [:] }
        var codes: [String: Int] = [:]
        for line in out.split(separator: "\n") {
            let cols = line.split(separator: "\t")
            if cols.count == 3, let code = Int(cols[1]) { codes[String(cols[2])] = code }
        }
        return codes
    }

    private static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    private static func describe(_ c: [String: Int]) -> String {
        let time = String(format: "%02d:%02d", c["Hour"] ?? 0, c["Minute"] ?? 0)
        if let wd = c["Weekday"] { return "\(weekdayNames[wd % 8]) \(time)" }
        if let day = c["Day"] { return "Day \(day) \(time)" }
        if c["Hour"] == nil { return "Hourly at :\(String(format: "%02d", c["Minute"] ?? 0))" }
        return "Daily \(time)"
    }

    private static func nextDate(_ c: [String: Int]) -> Date? {
        var parts = DateComponents()
        parts.minute = c["Minute"] ?? 0
        parts.hour = c["Hour"]
        parts.day = c["Day"]
        parts.month = c["Month"]
        if let wd = c["Weekday"] { parts.weekday = (wd % 7) + 1 }   // launchd 0/7 = Sunday
        return Calendar.current.nextDate(after: Date(), matching: parts, matchingPolicy: .nextTime)
    }

    // MARK: Hermes cron

    private static func hermes() -> [ScheduledJob] {
        let url = home.appendingPathComponent(".hermes/cron/jobs.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobs = root["jobs"] as? [[String: Any]] else { return [] }
        return jobs.map { j in
            let lastStatus = j["last_status"] as? String
            let error = j["last_error"] as? String
            let status: ScheduledJob.Status = switch lastStatus {
            case "ok": .ok
            case nil: .unknown
            default: (error?.contains("skip") == true) ? .skipped : .failed
            }
            let expr = (j["schedule_display"] as? String) ?? ""
            return ScheduledJob(
                id: "hermes-" + ((j["id"] as? String) ?? UUID().uuidString), source: .hermes,
                name: (j["name"] as? String) ?? "Untitled job",
                detail: (j["deliver"] as? String).map { "→ \($0)" },
                schedule: CronText.describe(expr),
                nextRun: iso(j["next_run_at"]), lastRun: iso(j["last_run_at"]),
                status: status, lastError: error,
                enabled: (j["enabled"] as? Bool) ?? true && (j["state"] as? String) != "paused",
                logURL: nil, launchdLabel: nil)
        }
    }

    // MARK: OpenClaw cron

    private static func openclaw() -> [ScheduledJob] {
        let cli = home.appendingPathComponent(".openclaw/bin/openclaw").path
        guard FileManager.default.isExecutableFile(atPath: cli),
              let out = run(cli, ["cron", "list", "--json"], timeout: 30),
              let start = out.firstIndex(of: "{"),
              let root = try? JSONSerialization.jsonObject(with: Data(out[start...].utf8)) as? [String: Any],
              let jobs = root["jobs"] as? [[String: Any]] else { return [] }
        return jobs.map { j in
            let sched = j["schedule"] as? [String: Any] ?? [:]
            let schedule: String
            if let every = sched["everyMs"] as? Double {
                schedule = "Every \(Int(every / 60000)) min"
            } else if let expr = sched["expr"] as? String {
                schedule = CronText.describe(expr)
            } else {
                schedule = (sched["kind"] as? String) ?? "—"
            }
            let lastStatus = j["lastRunStatus"] as? String
            let status: ScheduledJob.Status = switch lastStatus {
            case "ok": .ok
            case "skipped": .skipped
            case nil: .unknown
            default: .failed
            }
            func ms(_ key: String) -> Date? {
                (j[key] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            }
            return ScheduledJob(
                id: "openclaw-" + ((j["id"] as? String) ?? UUID().uuidString), source: .openclaw,
                name: (j["displayName"] as? String) ?? (j["name"] as? String) ?? "Job",
                detail: (j["agentId"] as? String).map { "agent \($0)" },
                schedule: schedule, nextRun: ms("nextRunAtMs"), lastRun: ms("lastRunAtMs"),
                status: status, lastError: j["lastRunError"] as? String,
                enabled: (j["enabled"] as? Bool) ?? true, logURL: nil, launchdLabel: nil)
        }
    }

    // MARK: Planner's own reminders

    private static func planner() -> [ScheduledJob] {
        // "waReminders.enabled" = WhatsAppReminders.enabledKey, which is main-actor isolated.
        guard UserDefaults.standard.bool(forKey: "waReminders.enabled") else { return [] }
        return ReminderSlot.allCases.map { slot in
            let key = slot.timeKey
            let minutes = UserDefaults.standard.object(forKey: key) as? Int ?? slot.defaultMinutes
            var parts = DateComponents()
            parts.hour = minutes / 60
            parts.minute = minutes % 60
            let next = Calendar.current.nextDate(after: Date(), matching: parts, matchingPolicy: .nextTime)
            return ScheduledJob(
                id: "planner-\(key)", source: .planner,
                name: slot == .today ? "WhatsApp: today's appointments" : "WhatsApp: tomorrow's appointments",
                detail: nil, schedule: String(format: "Daily %02d:%02d", minutes / 60, minutes % 60),
                nextRun: next, lastRun: nil, status: .unknown, lastError: nil,
                enabled: true, logURL: nil, launchdLabel: nil)
        }
    }

    // MARK: Helpers

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func iso(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.currentDirectoryURL = FileManager.default.temporaryDirectory
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()
        return String(data: output, encoding: .utf8)
    }
}

/// Plain-English text for common 5-field cron expressions; falls back to the expression.
enum CronText {
    static func describe(_ expr: String) -> String {
        let f = expr.split(separator: " ").map(String.init)
        guard f.count == 5, let minute = Int(f[0]), let hour = Int(f[1]) else {
            return expr.isEmpty ? "—" : "cron \(expr)"
        }
        let time = String(format: "%02d:%02d", hour, minute)
        let (dom, month, dow) = (f[2], f[3], f[4])
        if dom == "*", month == "*", dow == "*" { return "Daily \(time)" }
        if dom == "*", month == "*" {
            let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            let days = dow.split(separator: ",").compactMap { Int($0) }.map { names[$0 % 8] }
            if days.count == 5, !days.contains("Sat"), !days.contains("Sun") { return "Weekdays \(time)" }
            return days.isEmpty ? "cron \(expr)" : "\(days.joined(separator: ", ")) \(time)"
        }
        if month == "*", dow == "*", let day = Int(dom) { return "Monthly on day \(day), \(time)" }
        return "cron \(expr)"
    }
}

/// Sidebar ▸ Schedule: every scheduled background job on this Mac, by source, soonest first.
struct MacSchedulePane: View {
    @State private var jobs: [ScheduledJob] = []
    @State private var loading = false
    @State private var lastLoaded: Date?
    @State private var message: String?
    @State private var selectedID: ScheduledJob.ID?

    private let refreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        List(selection: $selectedID) {
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ScheduledJob.Source.allCases, id: \.self) { source in
                let rows = jobs.filter { $0.source == source }
                    .sorted { ($0.nextRun ?? .distantFuture) < ($1.nextRun ?? .distantFuture) }
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { row($0) }
                    } header: {
                        Label("\(source.rawValue) (\(rows.count))", systemImage: source.symbol)
                    }
                }
            }
            if jobs.isEmpty && !loading {
                ContentUnavailableView("No scheduled jobs found", systemImage: "clock.badge.questionmark",
                                       description: Text("Digital Workforce LaunchAgents, Hermes cron and OpenClaw cron jobs show up here."))
            }
        }
        .navigationTitle("Schedule")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button { Task { await reload() } } label: {
                    if loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .help("Refresh")
            }
        }
        .task { await reload() }
        .onReceive(refreshTimer) { _ in Task { await reload() } }
    }

    private var subtitle: String {
        let next = jobs.filter(\.enabled).compactMap(\.nextRun).filter { $0 > Date() }.min()
        let failing = jobs.filter { $0.status == .failed }.count
        var parts = ["\(jobs.count) scheduled job\(jobs.count == 1 ? "" : "s")"]
        if let next { parts.append("next \(next.formatted(.relative(presentation: .named)))") }
        if failing > 0 { parts.append("\(failing) failing") }
        return parts.joined(separator: " · ")
    }

    private func row(_ job: ScheduledJob) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon(job)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(job.name).font(.body.weight(.medium))
                    if let detail = job.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    if !job.enabled {
                        Text("Paused").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                HStack(spacing: 10) {
                    Label(job.schedule, systemImage: "repeat").labelStyle(.titleAndIcon)
                    if let last = job.lastRun {
                        Text("Last run \(last.formatted(.relative(presentation: .named)))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let error = job.lastError, job.status != .ok {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(job.status == .failed ? .red : .orange)
                        .lineLimit(2)
                        .help(error)
                }
            }
            Spacer(minLength: 8)
            if let next = job.nextRun, job.enabled {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(next.formatted(.relative(presentation: .named)))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    Text(next.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .popover(isPresented: Binding(
            get: { selectedID == job.id },
            set: { if !$0, selectedID == job.id { selectedID = nil } }
        ), arrowEdge: .trailing) {
            JobDetailView(job: job, runNow: { runNow($0, name: job.name) })
        }
        .contextMenu { actions(job) }
    }

    @ViewBuilder
    private func actions(_ job: ScheduledJob) -> some View {
        if let label = job.launchdLabel {
            Button("Run Now") { runNow(label, name: job.name) }
        }
        if let log = job.logURL {
            Button("Open Last Log") { NSWorkspace.shared.open(log) }
        }
        if let error = job.lastError {
            Button("Copy Error") { copy(error) }
        }
    }

    @ViewBuilder
    private func statusIcon(_ job: ScheduledJob) -> some View {
        switch job.status {
        case .ok:      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Last run succeeded")
        case .failed:  Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help("Last run failed")
        case .skipped: Image(systemName: "forward.circle.fill").foregroundStyle(.orange).help("Last run was skipped")
        case .unknown: Image(systemName: "circle.dotted").foregroundStyle(.secondary).help("No run recorded yet")
        }
    }

    private func reload() async {
        guard !loading else { return }
        loading = true
        let loaded = await Task.detached(priority: .userInitiated) { ScheduleLoader.loadAll() }.value
        jobs = loaded
        lastLoaded = Date()
        loading = false
    }

    /// Starts a Digital Workforce job immediately (`launchctl kickstart`).
    private func runNow(_ label: String, name: String) {
        let target = "gui/\(getuid())/\(label)"
        Task.detached {
            ScheduleLoader.run("/bin/launchctl", ["kickstart", target])
            await MainActor.run { message = "Started “\(name)” — refresh in a moment for its result." }
        }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Click-through details for one scheduled job: full schedule, run times, the untruncated
/// last error and the actions available for its source.
private struct JobDetailView: View {
    let job: ScheduledJob
    let runNow: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: job.source.symbol).foregroundStyle(.secondary)
                Text(job.name).font(.headline)
                if !job.enabled {
                    Text("Paused").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                field("Source", job.source.rawValue)
                if let detail = job.detail { field("Target", detail) }
                field("Schedule", job.schedule)
                field("Next run", job.enabled ? job.nextRun.map(dateText) ?? "—" : "Paused")
                field("Last run", job.lastRun.map(dateText) ?? "No run recorded")
                field("Status", statusText)
                if let label = job.launchdLabel { field("launchd", label) }
            }
            .font(.callout)
            if let error = job.lastError {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last error").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        Text(error)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(job.status == .failed ? .red : .orange)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
            }
            HStack {
                if let label = job.launchdLabel {
                    Button("Run Now") { runNow(label); dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                if let log = job.logURL {
                    Button("Open Last Log") { NSWorkspace.shared.open(log) }
                }
                if let error = job.lastError {
                    Button("Copy Error") { copy(error) }
                }
                Spacer()
            }
            if job.launchdLabel == nil {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func field(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }

    private func dateText(_ date: Date) -> String {
        "\(date.formatted(date: .abbreviated, time: .shortened)) (\(date.formatted(.relative(presentation: .named))))"
    }

    private var statusText: String {
        switch job.status {
        case .ok: "Last run succeeded"
        case .failed: "Last run failed"
        case .skipped: "Last run was skipped"
        case .unknown: "No run recorded yet"
        }
    }

    private var hint: String {
        switch job.source {
        case .hermes: "Managed by Hermes — edit or run it with `hermes cron`."
        case .openclaw: "Managed by OpenClaw — edit or run it with `openclaw cron`."
        case .planner: "Change this time in Settings ▸ WhatsApp reminders."
        case .workforce: ""
        }
    }
}
