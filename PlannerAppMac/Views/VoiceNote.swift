import AppKit
import AVFoundation
import SwiftUI
import WhisperKit

/// Voice notes to the agent, as in Wiki LLM and LahLah Voice: hold the mic (or the right ⌥ key)
/// and talk, release to send; slide left to cancel; slide up, or just tap, to keep recording
/// hands-free and send with the button. Speech becomes text on this Mac with Whisper (WhisperKit,
/// large-v3 turbo), biased toward Planner's own words (list names, agents), and goes straight to
/// the prompt of the agent in front (Claude Code, Codex, Hermes or OpenClaw).
@MainActor
final class VoiceNote: ObservableObject {
    static let shared = VoiceNote()

    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case message(String)     // a short notice (no speech, permission, model download…)
    }

    @Published private(set) var phase: Phase = .idle
    /// Recording continues after the press ends; the person sends or cancels with buttons.
    @Published var locked = false
    /// Recent input levels, 0…1, newest last: the waveform.
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 36)
    @Published private(set) var elapsed: TimeInterval = 0
    /// The loudness now, lightly smoothed: drives the wave and the mic's halo.
    var level: Float { levels.suffix(3).max() ?? 0 }
    /// True until the speech model is downloaded and loaded (the first use downloads ~600 MB).
    @Published private(set) var modelReady = false

    static let model = "large-v3-v20240930_626MB"
    /// Wiki LLM keeps the same model in its own folder: reuse it rather than download it again.
    /// Kept out of ~/Documents, which may sync to iCloud Drive.
    static var modelFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let wiki = support.appendingPathComponent("Wiki LLM/Whisper", isDirectory: true)
        if FileManager.default.fileExists(atPath: wiki.appendingPathComponent("models").path) { return wiki }
        return support.appendingPathComponent("Planner/Whisper", isDirectory: true)
    }

    private let engine = AVAudioEngine()
    private let buffer = SampleBuffer()
    private var started: Date?
    private var clock: Timer?
    private var whisper: Task<WhisperKit, Error>?
    private var noticeTask: Task<Void, Never>?

    // MARK: - Speech model

    /// Downloads (first time) and loads Whisper in the background, so the first note is quick.
    func prepare() { _ = loadWhisper() }

    private func loadWhisper() -> Task<WhisperKit, Error> {
        if let whisper { return whisper }
        let task = Task { () throws -> WhisperKit in
            try FileManager.default.createDirectory(at: Self.modelFolder, withIntermediateDirectories: true)
            let config = WhisperKitConfig(model: Self.model, downloadBase: Self.modelFolder,
                                          verbose: false, prewarm: true, load: true, download: true)
            let kit = try await WhisperKit(config)
            await MainActor.run { VoiceNote.shared.modelReady = true }
            return kit
        }
        whisper = task
        return task
    }

    /// Words Whisper should spell right: list names first (clients, staff, agents), then agent names.
    private static func vocabulary() -> [String] {
        var words = ["Planner", "Claude", "Codex", "Hermes", "OpenClaw", "Atlas", "Oracle", "Nova", "Helm", "Vesta",
                     "Mercury", "Muse", "Sage", "Sentinel", "Forge", "Ledger", "SWDA", "IBF", "WSQ", "TPQA", "ACLP"]
        let state = HermesBridge.workspaceURL.appendingPathComponent("planner-state.json")
        if let data = try? Data(contentsOf: state),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let lists = json["lists"] as? [[String: Any]] {
            words += lists.compactMap { $0["name"] as? String }.filter { $0.count <= 30 }.prefix(60)
        }
        return words
    }

    // MARK: - Recording

    func start() {
        guard phase != .recording, phase != .transcribing else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    VoiceNote.shared.notice(granted ? "Microphone allowed. Hold the mic again to talk."
                                                    : "Microphone access is off.")
                }
            }
            return
        default:
            notice("Allow the microphone for Planner in System Settings › Privacy & Security.")
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            return
        }
        prepare()
        buffer.reset()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { return notice("No microphone found.") }
        let samples = buffer
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { pcm, _ in
            // Resample to 16 kHz mono, which Whisper expects.
            let ratio = 16_000 / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return pcm
            }
            guard error == nil, let data = out.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
            samples.append(chunk)
            let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(max(chunk.count, 1)))
            let level = min(1, rms * 9)
            Task { @MainActor in VoiceNote.shared.push(level: level) }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return notice("Couldn't start the microphone: \(error.localizedDescription)")
        }
        started = Date()
        elapsed = 0
        levels = Array(repeating: 0, count: levels.count)
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                if let s = VoiceNote.shared.started { VoiceNote.shared.elapsed = Date().timeIntervalSince(s) }
            }
        }
        phase = .recording
    }

    /// Ends the recording; sends it to the agent unless `send` is false.
    func stop(send: Bool) {
        guard phase == .recording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        clock?.invalidate()
        clock = nil
        started = nil
        locked = false
        let audio = buffer.take()
        guard send else { phase = .idle; return }
        guard audio.count > 16_000 / 3 else { return notice("Hold the mic while you talk.") }
        phase = .transcribing
        let words = Self.vocabulary()
        Task {
            do {
                let kit = try await loadWhisper().value
                let text = try await Self.transcribe(audio, with: kit, vocabulary: words)
                if text.isEmpty {
                    notice("I didn't catch any words.")
                } else {
                    AgentPanelTabs.shared.submitVoice(text)
                    phase = .idle
                }
            } catch {
                whisper = nil   // try loading again next time
                notice("Speech recognition failed: \(error.localizedDescription)")
            }
        }
    }

    private static func transcribe(_ audio: [Float], with kit: WhisperKit, vocabulary: [String]) async throws -> String {
        var options = DecodingOptions(task: .transcribe, language: "en", temperature: 0,
                                      usePrefillPrompt: true, skipSpecialTokens: true,
                                      withoutTimestamps: true)
        if let tokenizer = kit.tokenizer, !vocabulary.isEmpty {
            // WhisperKit keeps only the end of a long prompt, so the most relevant words go last.
            options.promptTokens = tokenizer.encode(text: " " + vocabulary.reversed().joined(separator: ", ") + ".")
        }
        let results = try await kit.transcribe(audioArray: audio, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: #"\[(BLANK_AUDIO|MUSIC|NOISE|SILENCE)\]|\((silence|music)\)"#,
                                  with: "", options: [.regularExpression, .caseInsensitive])
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func push(level: Float) {
        guard phase == .recording else { return }
        levels.removeFirst()
        levels.append(level)
    }

    private func notice(_ text: String) {
        phase = .message(text)
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, case .message = phase else { return }
            phase = .idle
        }
    }

    // MARK: - Hold the right ⌥ key to talk

    private var keyMonitor: Any?
    private var keyDown = false

    /// Right Option alone, held: talk; released: send. Pressing another key while it's held
    /// cancels, so ⌥ shortcuts and special characters still work.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            let note = VoiceNote.shared
            if event.type == .keyDown {
                if note.keyDown { note.keyDown = false; note.stop(send: false) }
                return event
            }
            guard event.keyCode == 61 else { return event }          // right Option
            let pressed = event.modifierFlags.contains(.option)
            let ready: Bool = { if case .message = note.phase { return true }; return note.phase == .idle }()
            if pressed, !note.keyDown, ready {
                note.keyDown = true
                note.start()
            } else if !pressed, note.keyDown {
                note.keyDown = false
                if !note.locked { note.stop(send: true) }
            }
            return event
        }
    }
}

/// Audio samples gathered on the audio thread.
private final class SampleBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock = NSLock()
    func reset() { lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock() }
    func append(_ chunk: [Float]) { lock.lock(); samples.append(contentsOf: chunk); lock.unlock() }
    func take() -> [Float] { lock.lock(); defer { samples = []; lock.unlock() }; return samples }
}

// MARK: - The bar under the agent's terminal

/// LahLah Voice's colours (see the LahLah Voice app's Brand.swift), so the bar looks like its pill.
private enum LahLah {
    static let ember = Color(red: 0.91, green: 0.455, blue: 0.231)
    static let ink = Color(red: 0.11, green: 0.106, blue: 0.098)
    static let muted = Color(red: 0.42, green: 0.41, blue: 0.38)
    static let hairline = Color.black.opacity(0.08)
}

/// The composer under the agent's terminal, drawn as LahLah Voice's pill: one white capsule the
/// width of the panel, with the mic on its left (click once, talk, then Send; or hold to talk), the
/// waveform, and the hint or the recording controls. Accent colours follow Planner's theme.
struct VoiceNoteBar: View {
    var agentName: String

    @ObservedObject private var note = VoiceNote.shared
    @State private var pressStart: Date?
    @State private var drag: CGSize = .zero
    @State private var cancelled = false
    @State private var hovering = false

    private let cancelDistance: CGFloat = 90
    private let lockDistance: CGFloat = 50
    private let micSize: CGFloat = 48

    var body: some View {
        HStack(spacing: 12) {
            micButton
            content
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .frame(height: 64)
        .frame(maxWidth: .infinity)
        .background(.white, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.accent.opacity(note.phase == .recording ? 0.6 : 0.18), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        .foregroundStyle(LahLah.ink)
        .environment(\.colorScheme, .light)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black)
        .onAppear {
            note.installKeyMonitor()
            note.prepare()
        }
    }

    @ViewBuilder private var content: some View {
        switch note.phase {
        case .recording:
            Text(timeText).font(.callout.monospacedDigit().weight(.semibold))
            VoiceWave(level: note.level)
            if note.locked {
                Spacer(minLength: 4)
                Button { note.stop(send: false) } label: {
                    Image(systemName: "trash").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.red).frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Discard this voice note")
                sendButton
            } else {
                Text(cancelled ? "Release to cancel" : "Release to send · ‹ slide to cancel")
                    .font(.callout).foregroundStyle(cancelled ? Color.red : LahLah.muted)
                    .lineLimit(1)
                    .offset(x: max(-60, min(0, drag.width / 2)))
                Spacer(minLength: 0)
            }
        case .transcribing:
            ProgressView().controlSize(.small)
            Text(note.modelReady ? "Writing your message to \(agentName)…"
                                 : "Getting the speech model ready (first time downloads about 600 MB)…")
                .font(.callout.weight(.medium)).lineLimit(1)
            Spacer(minLength: 0)
        case .message(let text):
            Image(systemName: "info.circle").foregroundStyle(LahLah.muted)
            Text(text).font(.callout).foregroundStyle(LahLah.muted).lineLimit(2)
            Spacer(minLength: 0)
        case .idle:
            VoiceWave(level: hovering ? 0.5 : 0.3, barCount: 9, maxHeight: 24)
            Text("Click the mic, talk to \(agentName), then Send · or hold to talk · or right ⌥")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(LahLah.muted)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    /// Send: accent capsule, white "↑ Send". Return also sends.
    private var sendButton: some View {
        Button { note.stop(send: true) } label: {
            Label("Send", systemImage: "arrow.up")
                .font(.callout.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .foregroundStyle(.white)
                .background(Theme.accent, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: [])
        .help("Send to \(agentName) (Return)")
    }

    private var timeText: String {
        let s = Int(note.elapsed)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The mic inside the pill: a light accent disc with an accent ring (red and pulsing while
    /// recording). Click once to start hands-free, then Send; or hold to talk and release to send.
    private var micButton: some View {
        let recording = note.phase == .recording
        let tint = recording ? Color.red : Theme.accent
        return Image(systemName: recording ? "mic.fill" : "mic")
            .font(.system(size: micSize * 0.42, weight: .semibold))
            .foregroundStyle(recording ? .white : tint)
            .frame(width: micSize, height: micSize)
            .background(Circle().fill(recording ? tint : tint.opacity(hovering ? 0.22 : 0.14)))
            .overlay(Circle().strokeBorder(tint, lineWidth: 2.5))
            .background(
                Circle()
                    .fill(tint.opacity(recording ? 0.25 : 0))
                    .scaleEffect(recording ? 1.15 + CGFloat(note.level) * 0.45 : 1)
            )
            .scaleEffect(hovering && !recording ? 1.05 : 1)
            .animation(.easeOut(duration: 0.12), value: note.level)
            .animation(.easeOut(duration: 0.15), value: note.phase)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .frame(width: micSize + 8, height: micSize + 8)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if pressStart == nil {
                            pressStart = Date()
                            cancelled = false
                            if note.phase != .recording { note.start() }
                        }
                        drag = value.translation
                        guard note.phase == .recording, !note.locked else { return }
                        cancelled = value.translation.width < -cancelDistance
                        if value.translation.height < -lockDistance { note.locked = true }
                    }
                    .onEnded { _ in
                        let held = pressStart.map { Date().timeIntervalSince($0) } ?? 0
                        pressStart = nil
                        drag = .zero
                        guard note.phase == .recording else { return }
                        if note.locked {
                            // Clicking the mic again while hands-free sends, like Send.
                            if held < 0.35, !cancelled { note.stop(send: true) }
                            return
                        }
                        if cancelled {
                            note.stop(send: false)
                        } else if held < 0.35 {
                            note.locked = true          // a click: keep recording hands-free
                        } else {
                            note.stop(send: true)       // held and released: send
                        }
                        cancelled = false
                    }
            )
            .help("Click once, talk, then press Send (or click the mic again). Or hold to talk and release to send.")
            .accessibilityLabel("Voice note to \(agentName)")
            .accessibilityAddTraits(.isButton)
    }
}

/// LahLah Voice's wave: a symmetric row of small capsules in ink, every fourth one in the accent, that
/// swells with the voice and ripples while it listens (quiet, it reads as a dotted line).
private struct VoiceWave: View {
    var level: Float
    var barCount = 27
    var maxHeight: CGFloat = 32

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(index % 4 == 0 ? Theme.accent : LahLah.ink)
                        .frame(width: 4, height: height(index, time))
                }
            }
            .frame(height: maxHeight)
        }
        .accessibilityHidden(true)
    }

    private func height(_ index: Int, _ time: Double) -> CGFloat {
        let position = Double(index) / Double(max(barCount - 1, 1))
        let shape = pow(abs(sin(position * .pi * 2)), 1.4)
        let loudness = min(1, Double(level) * 1.6)
        let ripple = 0.72 + 0.28 * sin(time * 7 + Double(index) * 0.9)
        return 5 + (maxHeight - 5) * CGFloat(shape * (0.18 + 0.82 * loudness) * ripple)
    }
}
