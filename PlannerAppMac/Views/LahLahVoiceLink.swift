import AppKit
import SwiftUI

/// Speaking to the agent with LahLah Voice, the Mac dictation app (like Wispr Flow).
///
/// LahLah Voice works in any app on its own: hold Fn, speak, and it pastes into the focused
/// field, which here is the agent's terminal. The mic button is a visible way to do the same:
/// it focuses the terminal, then asks LahLah Voice to start or stop hands-free dictation over a
/// distributed notification. LahLah Voice only accepts it while this app is in front, and tells
/// us when it's listening so the button can show it.
@MainActor
final class LahLahVoiceLink: ObservableObject {
    static let shared = LahLahVoiceLink()

    enum State: String { case idle, listening, working }

    @Published private(set) var state: State = .idle

    private static let bundleID = "com.tertiaryinfotech.novavoice.mac"
    private static let toggle = Notification.Name("com.tertiaryinfotech.lahlahvoice.toggleDictation")
    private static let stateChanged = Notification.Name("com.tertiaryinfotech.lahlahvoice.state")
    private static let website = URL(string: "https://alfredang.github.io/lahlahvoice/")!

    private init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Self.stateChanged, object: nil, queue: .main
        ) { note in
            let state = (note.object as? String).flatMap(State.init(rawValue:)) ?? .idle
            MainActor.assumeIsolated { LahLahVoiceLink.shared.state = state }
        }
    }

    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil }

    /// Starts dictation, or finishes it and pastes the text. Opens LahLah Voice in the
    /// background first if it isn't running, and its website if it isn't installed.
    func toggleDictation() {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty {
            Self.postToggle()
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else {
            NSWorkspace.shared.open(Self.website)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false  // Keep this app in front: that's where the text goes.
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
            guard error == nil else { return }
            // Give it a moment to start listening for the toggle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { Self.postToggle() }
        }
    }

    private static func postToggle() {
        DistributedNotificationCenter.default().postNotificationName(
            toggle, object: nil, userInfo: nil, deliverImmediately: true)
    }
}

/// The mic in the agent panel header. `focusAgent` gives the agent's terminal the keyboard,
/// so the dictated text is pasted there.
struct LahLahVoiceButton: View {
    var focusAgent: () -> Void

    @ObservedObject private var link = LahLahVoiceLink.shared

    var body: some View {
        Button {
            focusAgent()
            link.toggleDictation()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(link.state == .listening ? Color.red : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private var symbol: String {
        switch link.state {
        case .idle: "mic"
        case .listening: "mic.fill"
        case .working: "ellipsis"
        }
    }

    private var help: String {
        guard link.isInstalled else { return "Speak to the agent: get LahLah Voice" }
        switch link.state {
        case .idle: return "Speak to the agent with LahLah Voice. Click, talk, click again. Or hold Fn."
        case .listening: return "Listening. Click to finish and paste into the agent"
        case .working: return "Writing your text…"
        }
    }
}

