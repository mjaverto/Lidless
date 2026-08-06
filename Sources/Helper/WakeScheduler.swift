import Foundation
import IOKit.pwr_mgt

/// Thin adapter over the IOKit scheduled-power-event calls.
///
/// Deliberately as dumb as it can be: three functions, no filtering, no policy,
/// no interpretation. Nothing here can be unit-tested — `IOPMSchedulePowerEvent`
/// and `IOPMCancelScheduledPowerEvent` must run as root and change real machine
/// state — so anything worth testing lives in `ScheduledWake` instead, and this
/// file is kept small enough to review by eye.
enum WakeScheduler {

    /// Every pending power event on the Mac, ours and everyone else's.
    ///
    /// Returns nil only when the array comes back in a shape we can't read.
    /// A NULL result is *not* that case: IOKit documents NULL as "there are no
    /// scheduled events", which is a real answer, so it maps to `[]`. Callers
    /// need the two kept apart — an unreadable schedule must never be reported
    /// as an empty one.
    static func copyEvents() -> [[String: Any]]? {
        guard let raw = IOPMCopyScheduledPowerEvents() else { return [] }
        return (raw.takeRetainedValue() as? [[String: Any]])
    }

    @discardableResult
    static func schedule(_ date: Date, ownerID: String) -> IOReturn {
        IOPMSchedulePowerEvent(date as CFDate,
                               ownerID as CFString,
                               ScheduledWake.eventType as CFString)
    }

    @discardableResult
    static func cancel(_ date: Date, ownerID: String) -> IOReturn {
        IOPMCancelScheduledPowerEvent(date as CFDate,
                                      ownerID as CFString,
                                      ScheduledWake.eventType as CFString)
    }

    /// Human-readable form of an IOKit status, for the error we send back to
    /// the app. `kIOReturnNotPrivileged` is called out by name because it's the
    /// one failure with an obvious cause — this ran somewhere other than root.
    static func describe(_ status: IOReturn) -> String {
        switch status {
        case kIOReturnNotPrivileged: return "Not permitted to change the wake schedule."
        case kIOReturnBadArgument:   return "The system rejected the wake time."
        default:                     return String(format: "IOKit error 0x%08x", UInt32(bitPattern: status))
        }
    }
}
