import Foundation
import AVFoundation
import Speech

/// Wraps Apple's on-device `SFSpeechRecognizer` + `AVAudioEngine` to provide live
/// speech-to-text. All transcription happens through the native iOS speech stack.
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
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

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

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.request?.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
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
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        if state == .listening { state = .idle }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }
}
