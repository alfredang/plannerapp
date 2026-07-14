import Foundation
import AVFoundation
import Speech

/// Wraps Apple's on-device `SFSpeechRecognizer` + `AVAudioEngine` to provide live
/// speech-to-text. All transcription happens through the native Apple speech stack.
/// Cross-platform: the `AVAudioSession` calls are iOS-only (macOS has no audio session).
@Observable
@MainActor
final class SpeechRecognizer {

    enum State: Equatable {
        case idle
        case listening
        case unauthorized
        case unavailable
    }

    private(set) var transcript: String = ""
    private(set) var state: State = .idle
    var errorMessage: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    // Built on demand (see `engine`) so nothing audio-related — and no microphone permission
    // prompt — is touched until the user actually starts dictation. The assistant screen, which
    // is the app's first tab, must open silently. @ObservationIgnored keeps it out of @Observable.
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var engine: AVAudioEngine {
        if let audioEngine { return audioEngine }
        let e = AVAudioEngine()
        audioEngine = e
        return e
    }

    var isListening: Bool { state == .listening }

    /// Request both speech-recognition and microphone permission up front.
    func requestAuthorization() async {
        let speechAuth = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard speechAuth == .authorized else { state = .unauthorized; return }

        let micAuth = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
        if !micAuth { state = .unauthorized }
    }

    func toggle() {
        isListening ? stop() : start()
    }

    func start() {
        guard let recognizer, recognizer.isAvailable else { state = .unavailable; return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            state = .unauthorized
            return
        }

        transcript = ""
        errorMessage = nil

        do {
            try configureAudioSession()

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // Prefer on-device dictation when the device supports it (privacy + offline).
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            self.request = request

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.request?.append(buffer)
            }

            engine.prepare()
            try engine.start()
            state = .listening

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                Task { @MainActor in
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if error != nil || (result?.isFinal ?? false) {
                        self.stop()
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            stop()
        }
    }

    func stop() {
        if let audioEngine, audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        if state == .listening { state = .idle }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func configureAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
    }
}
