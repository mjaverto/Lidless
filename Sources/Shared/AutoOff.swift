import Foundation

/// Auto-off timer logic (pure, unit-testable).
///
/// Keep-awake is a convenience, not a safety mechanism, so the countdown lives
/// in the app — if the app dies the helper watchdog restores sleep anyway.
public enum AutoOff {
    /// Selectable durations (minutes). `0` means "no auto-off" (stay on until off).
    public static let presetMinutes = DurationFormat.standardMinutes

    /// When a timer started `minutes` ago from `start` should fire.
    public static func deadline(from start: Date, minutes: Int) -> Date {
        start.addingTimeInterval(TimeInterval(minutes) * 60)
    }

    /// Seconds left until `deadline` (never negative).
    public static func remaining(deadline: Date, now: Date) -> TimeInterval {
        max(0, deadline.timeIntervalSince(now))
    }

    /// True once `now` has reached or passed `deadline`.
    public static func isExpired(deadline: Date, now: Date) -> Bool {
        now >= deadline
    }

    /// Countdown like `1:05:09` (with hours) or `9:42` (under an hour).
    ///
    /// Forwards to `DurationFormat` so this and the scheduled-wake countdown —
    /// which can be on screen at the same time, in the same popover — can't
    /// drift apart.
    public static func formatCountdown(_ seconds: TimeInterval) -> String {
        DurationFormat.formatCountdown(seconds)
    }

    /// Menu label for a duration, e.g. `15 min`, `1 hour`, `2 hours`.
    public static func optionLabel(minutes: Int) -> String {
        DurationFormat.optionLabel(minutes: minutes)
    }
}
