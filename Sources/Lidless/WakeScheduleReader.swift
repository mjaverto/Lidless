import Foundation
import IOKit.pwr_mgt

/// Reads the system's scheduled power events.
///
/// Unprivileged on purpose. Changing the schedule needs root, but reading it
/// doesn't — `pmset -g sched` prints the same list without `sudo` — so the app
/// reads it directly instead of asking the helper. That keeps the display path
/// off the XPC connection entirely: it can't time out, and it doesn't stop
/// working against a helper too old to answer the new calls. It's the same
/// division `PowerManager` already uses for the sleep flag.
enum WakeScheduleReader {

    /// Every pending power event on the Mac, or nil if the list couldn't be read.
    ///
    /// `nil` and `[]` mean different things and callers must keep them apart.
    /// IOKit documents a NULL return as "there are no scheduled events" — a
    /// real answer — so that becomes `[]`. `nil` is reserved for a result we
    /// genuinely couldn't interpret, and must never be shown as "no wake
    /// scheduled": that's a claim about the machine made from data that says
    /// nothing, which is the mistake `PowerParsers` exists to avoid.
    static func copyEvents() -> [[String: Any]]? {
        guard let raw = IOPMCopyScheduledPowerEvents() else { return [] }
        return raw.takeRetainedValue() as? [[String: Any]]
    }
}
