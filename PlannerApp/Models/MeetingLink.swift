import Foundation

/// Video-meeting links for appointments. The link lives in the item's notes — either inline
/// ("Link: meet.google.com/abc-defg-hij", as pasted from an invite) or on a
/// "Meeting link: …" line written by the edit form — so it syncs through the existing
/// `notes` field with no CloudKit schema change, and older app versions still show it.
enum MeetingLink {
    /// Prefix of the line the edit form writes. Any URL may follow it.
    static let tag = "Meeting link:"

    /// Well-known meeting hosts recognised anywhere in the text, with or without https://.
    private static let hostPattern =
        #"(?i)\b(?:https?://)?(?:[a-z0-9-]+\.)*(?:meet\.google\.com|zoom\.us|zoom\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|whereby\.com|meet\.jit\.si|gotomeeting\.com|chime\.aws)(?:/[^\s<>()\[\]"',;]*)?"#
    /// A tagged line: "Meeting link: <anything up to whitespace>".
    private static let taggedPattern = #"(?im)^\s*Meeting link:\s*(\S+)"#

    /// The meeting link in `text`: a tagged line wins, else the first known meeting host.
    static func find(in text: String) -> String? {
        if let tagged = firstMatch(taggedPattern, in: text, group: 1) { return clean(tagged) }
        return firstMatch(hostPattern, in: text, group: 0).map(clean)
    }

    /// A tappable URL for a stored link ("meet.google.com/x" → "https://meet.google.com/x").
    static func url(for link: String) -> URL? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), url.host != nil else { return nil }
        return url
    }

    /// `notes` with its meeting link set to `link`: an existing link is replaced in place
    /// (or removed when `link` is empty); otherwise a "Meeting link:" line is appended.
    static func notes(_ notes: String, settingLink link: String) -> String {
        let new = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = find(in: notes)
        if current == new || (current == nil && new.isEmpty) { return notes }

        if let current, let range = notes.range(of: current) {
            var result = notes
            if new.isEmpty, let line = taggedLineRange(in: notes) {
                result.removeSubrange(line)          // drop the whole "Meeting link:" line
            } else {
                result.replaceSubrange(range, with: new)
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let line = "\(tag) \(new)"
        let base = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? line : base + "\n" + line
    }

    // MARK: - Helpers

    private static func firstMatch(_ pattern: String, in text: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    private static func taggedLineRange(in text: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: #"(?im)^\s*Meeting link:[^\n]*\n?"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return Range(match.range, in: text)
    }

    /// Drop sentence punctuation that rides along at the end of a pasted link.
    private static func clean(_ link: String) -> String {
        var s = link
        while let last = s.last, ".!?:".contains(last) { s.removeLast() }
        return s
    }
}

extension PlannerItem {
    /// The appointment's video-meeting link, if its notes (or title) carry one.
    var meetingLink: String? {
        guard kind == .appointment else { return nil }
        return MeetingLink.find(in: notes) ?? MeetingLink.find(in: title)
    }

    var meetingURL: URL? { meetingLink.flatMap(MeetingLink.url(for:)) }
}
