import Foundation
import IOKit.pwr_mgt

/// Scheduled-wake logic (pure, unit-testable).
///
/// The feature asks macOS to wake the Mac at a chosen time and then leave no
/// trace behind. The scheduling itself is a root-only IOKit call made by the
/// privileged helper (`IOPMSchedulePowerEvent`); everything *decided* about it
/// lives here, so it can be tested without root, without a real sleep, and
/// without touching the machine's power state.
///
/// The one fact this whole module is built around: the scheduled events belong
/// to the system, not to us. `IOPMCopyScheduledPowerEvents()` returns *every*
/// pending event on the Mac — macOS's own `com.apple.alarm.*` timers, anything
/// the user set with `pmset schedule`, and ours. So every decision here filters
/// by owner id *and* event type first. There is no operation in this app that
/// cancels a power event we didn't create, and `pmset schedule cancelall` — the
/// obvious shortcut — is exactly the bug that rule exists to prevent.
public enum ScheduledWake {

    // MARK: Identity

    /// The event type we schedule: `kIOPMAutoWake`, i.e. wake a sleeping Mac.
    ///
    /// Deliberately not `kIOPMAutoWakeOrPowerOn` ("wakepoweron"). Shutting the
    /// Mac down is the user withdrawing every intent they had; a machine that
    /// powers itself back on afterwards is alarming, not helpful.
    public static let eventType = kIOPMAutoWake

    /// The suffix that turns an app/helper identifier into our owner id.
    private static let ownerSuffix = ".wake"

    /// Owner id derived from the helper's Mach service label — the form the
    /// privileged helper uses, since it knows its label from the environment
    /// (`LidlessHelper.machLabelEnvKey`) and has no bundle of its own.
    ///
    ///     com.nghialuong.lidless.dev.helper  ->  com.nghialuong.lidless.dev.wake
    ///
    /// A label without the expected `.helper` suffix still yields a usable id
    /// rather than a crash or an empty string: an id we can't attribute is
    /// worse than an ugly one, because filtering falls back to matching
    /// everything.
    public static func ownerID(fromMachLabel label: String) -> String {
        let helperSuffix = ".helper"
        guard label.hasSuffix(helperSuffix) else { return label + ownerSuffix }
        return String(label.dropLast(helperSuffix.count)) + ownerSuffix
    }

    /// Owner id derived from the app's bundle id — the form the app uses when
    /// it reads the schedule back. Must agree with `ownerID(fromMachLabel:)`
    /// for the same install, or the app would read a schedule it can't see and
    /// report "nothing scheduled" while an event of ours sits in powerd.
    ///
    ///     com.nghialuong.lidless.dev  ->  com.nghialuong.lidless.dev.wake
    public static func ownerID(appBundleID: String) -> String {
        appBundleID + ownerSuffix
    }

    // MARK: Presets

    /// Selectable durations for "wake me in…".
    ///
    /// Debug builds get a one-minute option. Verifying this feature by hand
    /// means putting the Mac to sleep and waiting for it to wake up, and doing
    /// that on a 15-minute floor makes the check expensive enough that it stops
    /// getting done. It is `#if DEBUG` because a one-minute wake is a test
    /// affordance, not a thing to ship.
    public static var presetMinutes: [Int] {
        #if DEBUG
        return [1] + DurationFormat.standardMinutes
        #else
        return DurationFormat.standardMinutes
        #endif
    }

    /// Menu label for a duration, e.g. `15 min`, `1 hour`.
    public static func optionLabel(minutes: Int) -> String {
        DurationFormat.optionLabel(minutes: minutes)
    }

    /// Countdown like `12:41`, shown next to the absolute wake time.
    public static func formatCountdown(_ seconds: TimeInterval) -> String {
        DurationFormat.formatCountdown(seconds)
    }

    /// Seconds until `date` (never negative).
    public static func remaining(until date: Date, now: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(now))
    }

    // MARK: Scheduling

    /// When a wake requested `minutes` from `start` should fire, truncated to a
    /// whole second.
    ///
    /// powerd stores these at one-second resolution, so an un-truncated date
    /// would come back from `IOPMCopyScheduledPowerEvents()` slightly different
    /// from the one we sent — and the read-back check would then need a fuzzy
    /// comparison, which is a much worse thing to own than a rounding call.
    /// Truncating up front makes verification an exact match.
    public static func wakeDate(from start: Date, minutes: Int) -> Date {
        wholeSecond(start.addingTimeInterval(TimeInterval(minutes) * 60))
    }

    /// `date` with any sub-second part dropped.
    ///
    /// Applied again inside the helper rather than trusting the caller to have
    /// done it: the XPC method is an entry point, and a fractional date there
    /// would schedule fine and then fail its own read-back check, reporting
    /// failure for a wake that is genuinely on the machine.
    public static func wholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// Whether a date read back out of powerd is the one we asked for.
    ///
    /// Compared at whole-second resolution because that is the resolution the
    /// system stores. An exact `==` between a `Date` we constructed and one
    /// bridged back out of a `CFDate` is a stricter claim than the storage can
    /// support, and failing on it would mean telling the user their wake didn't
    /// take while the Mac sits there ready to wake.
    public static func isSameWakeInstant(_ lhs: Date, _ rhs: Date) -> Bool {
        wholeSecond(lhs) == wholeSecond(rhs)
    }

    // MARK: Reading the system schedule

    /// Wake dates belonging to `ownerID`, from the dictionaries that
    /// `IOPMCopyScheduledPowerEvents()` hands back.
    ///
    /// Keys are IOKit's (`IOPMKeys.h`): `time` (a Date), `scheduledby` (the
    /// owner string we passed when scheduling), `eventtype` (`"wake"` here).
    ///
    /// An entry missing a key, or holding an unexpected type, is skipped rather
    /// than guessed at — the same rule `PowerParsers` follows. A malformed
    /// entry defaulted into "ours" would put a foreign power event on the list
    /// of things we're willing to cancel, and there is no data here worth that.
    /// Sorted ascending, so callers can reason about "the next one" directly.
    public static func ownedWakeDates(events: [[String: Any]], ownerID: String) -> [Date] {
        events.compactMap { event -> Date? in
            guard let owner = event[kIOPMPowerEventAppNameKey] as? String, owner == ownerID,
                  let type = event[kIOPMPowerEventTypeKey] as? String, type == eventType,
                  let date = event[kIOPMPowerEventTimeKey] as? Date
            else { return nil }
            return date
        }
        .sorted()
    }

    /// The wake that will actually happen next: the earliest of ours still in
    /// the future, or nil if we have none pending.
    ///
    /// Earliest, not latest. If duplicates ever exist, powerd fires the soonest
    /// one — showing any other time would be telling the user something about
    /// their Mac that isn't true. (Duplicates are also cleaned up; see
    /// `surplusWakeDates`. This decides what to *display* while that happens.)
    ///
    /// Strictly in the future: an event whose moment has arrived has fired, and
    /// a countdown at or below zero is not a thing we should ever render.
    public static func pendingWake(events: [[String: Any]], ownerID: String, now: Date) -> Date? {
        ownedWakeDates(events: events, ownerID: ownerID).first { $0 > now }
    }

    /// Leftovers of ours worth cleaning up: events far enough past that powerd
    /// should already have purged them.
    ///
    /// The grace window matters. powerd removes a one-shot event once it fires,
    /// but "fires" and "is gone from the list" are not the same instant, and a
    /// reconcile that runs in between would otherwise ask the helper to cancel
    /// an event the system is in the middle of handling. Inside the window we
    /// neither display the event nor touch it — it is on its way out.
    public static func staleWakeDates(events: [[String: Any]],
                                      ownerID: String,
                                      now: Date,
                                      grace: TimeInterval = 60) -> [Date] {
        ownedWakeDates(events: events, ownerID: ownerID)
            .filter { $0 <= now.addingTimeInterval(-grace) }
    }

    /// Future events of ours beyond the first — i.e. the ones that shouldn't
    /// exist, since we hold at most one wake at a time. Cancelled on sight.
    ///
    /// Reaching this state means an earlier write was interrupted between its
    /// cancel and its schedule. Rare, but the cost of not handling it is the
    /// Mac waking at a time nothing in the UI ever mentioned.
    public static func surplusWakeDates(events: [[String: Any]],
                                        ownerID: String,
                                        now: Date) -> [Date] {
        Array(ownedWakeDates(events: events, ownerID: ownerID).filter { $0 > now }.dropFirst())
    }

    // MARK: Helper capability

    /// First helper version that implements the scheduled-wake XPC methods.
    public static let minimumHelperVersion = "0.2.0"

    /// Whether an installed helper can schedule wakes — or nil when its version
    /// string doesn't say.
    ///
    /// Every user upgrading into this feature has an older helper already
    /// running, and that helper's exported object has no `scheduleWake:`
    /// selector — calling it doesn't fail, it simply never replies, so the app
    /// would sit on `callWithTimeout` for six seconds and then apologise. The
    /// gate turns that into a disabled control.
    ///
    /// Three-valued rather than two, for the same reason
    /// `PowerParsers.sleepDisabled` is: a version we can't read is not a claim
    /// that the helper is old. Both answers disable the control, but they are
    /// different situations and deserve different words — "your helper needs
    /// reinstalling to use this" is a lie when what actually happened is that
    /// the daemon never answered. Callers decide; this doesn't decide for them.
    public static func helperSupportsScheduledWake(version: String) -> Bool? {
        compareVersions(version, minimumHelperVersion).map { $0 >= 0 }
    }

    /// Compare dotted numeric versions. Returns nil if either side isn't one.
    private static func compareVersions(_ lhs: String, _ rhs: String) -> Int? {
        guard let l = numericComponents(lhs), let r = numericComponents(rhs) else { return nil }
        for i in 0..<max(l.count, r.count) {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }

    /// Split a dotted version into its numbers, or nil if it isn't one.
    ///
    /// Each component must be digits and nothing else. `Int(_:)` is more
    /// permissive than it looks — it accepts a leading sign, so `"0.2.+0"`
    /// would otherwise parse as `[0, 2, 0]` and read as a helper new enough to
    /// call, which is precisely the misread this whole gate exists to prevent.
    private static func numericComponents(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var out: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let n = Int(part)
            else { return nil }
            out.append(n)
        }
        return out
    }
}
