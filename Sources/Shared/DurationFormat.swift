import Foundation

/// Duration presets and their user-facing formatting, shared by every timed
/// feature in the app (auto-off, scheduled wake).
///
/// This exists as its own namespace rather than living in whichever feature got
/// written first. Two features rendering a countdown into the same popover must
/// render it the same way, and the only way to guarantee that without a test
/// whose whole job is to pin two copies together is to have one copy. A feature
/// that later needs a genuinely different format should say so by not calling
/// in here — not by forking these three functions.
public enum DurationFormat {
    /// The durations every timed feature offers. A product constant, not a
    /// per-feature one: a user who learns the menu once should recognise it
    /// everywhere it appears.
    public static let standardMinutes = [15, 30, 60, 120, 240]

    /// Countdown like `1:05:09` (with hours) or `9:42` (under an hour).
    public static func formatCountdown(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// Menu label for a duration, e.g. `15 min`, `1 hour`, `2 hours`.
    public static func optionLabel(minutes: Int) -> String {
        guard minutes % 60 == 0 else { return "\(minutes) min" }
        let h = minutes / 60
        return h == 1 ? "1 hour" : "\(h) hours"
    }
}
