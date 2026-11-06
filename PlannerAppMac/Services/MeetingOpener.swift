import AppKit

/// Opens a video-meeting link so it actually appears in front of the user.
///
/// A plain URL open hands the link to the browser's most recent window. When that window is on
/// another desktop Space the browser activates but the screen doesn't move, so clicking
/// "Join meeting" looks like it did nothing and the tabs pile up out of sight. Chromium browsers
/// accept `--new-window`, which opens on the current Space; other browsers get the normal open.
enum MeetingOpener {
    private static let newWindowBrowserPrefixes = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser"]

    static func open(_ url: URL) {
        let workspace = NSWorkspace.shared
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        guard let browser = workspace.urlForApplication(toOpen: url),
              let bundleID = Bundle(url: browser)?.bundleIdentifier,
              newWindowBrowserPrefixes.contains(where: bundleID.hasPrefix) else {
            workspace.open(url, configuration: configuration)
            return
        }

        // The extra process passes the request to the running browser, then exits.
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--new-window", url.absoluteString]
        workspace.openApplication(at: browser, configuration: configuration) { _, error in
            guard error != nil else { return }
            let fallback = NSWorkspace.OpenConfiguration()
            fallback.activates = true
            workspace.open(url, configuration: fallback)
        }
    }
}
