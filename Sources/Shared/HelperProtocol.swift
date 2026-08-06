import Foundation

/// Identity of the privileged helper, derived from the owning app's bundle id so
/// that Debug (`.dev`) and Release builds get fully isolated daemons/services and
/// never collide. For app bundle id `com.nghialuong.lidless` the helper id —
/// which doubles as its LaunchDaemon label, Mach service name, and the `.plist`
/// basename — is `com.nghialuong.lidless.helper`.
public enum LidlessHelper {
    /// Label / Mach service name for a given app bundle id.
    public static func label(appBundleID: String) -> String { "\(appBundleID).helper" }

    /// Env var the generated LaunchDaemon plist passes to the (bundle-less) helper
    /// executable so it knows which Mach service to listen on without relying on
    /// an embedded bundle id.
    public static let machLabelEnvKey = "LIDLESS_MACH_LABEL"

    /// Fallback used only if the app bundle id / env var is unavailable.
    public static let fallbackLabel = "com.nghialuong.lidless.helper"

    /// The app bundle id a helper label was derived from — the inverse of
    /// `label(appBundleID:)`.
    public static func appBundleID(fromLabel label: String) -> String {
        let suffix = ".helper"
        guard label.hasSuffix(suffix) else { return label }
        return String(label.dropLast(suffix.count))
    }

    /// The Apple Developer Team ID both the app and the helper are signed with.
    public static let teamID = "TAFDRXJZSR"

    /// Code signing requirement the helper demands of anything connecting to it.
    ///
    /// The Mach service a `SMAppService` daemon registers is reachable by any
    /// process on the machine, so without this every local program can ask a
    /// root daemon to do root things. That was survivable while the only verb
    /// was keep-awake — it dies with the app, and the watchdog clears it within
    /// 90 seconds either way — but a scheduled wake outlives the app by design
    /// and no watchdog touches it, so "any process can set one" is a different
    /// proposition.
    ///
    /// Pins both the identity (this app, not merely something of ours) and the
    /// team, and requires an Apple-issued chain so a self-signed binary
    /// claiming the same identifier doesn't match. `anchor apple generic`
    /// covers Developer ID and Apple Development certificates alike, so a
    /// locally-built `.dev` app satisfies this the same way a released one does.
    ///
    /// Checked per message against the peer's audit token, which is what makes
    /// it free of the PID-reuse race that a `processIdentifier`-based check has.
    public static func codeSigningRequirement(appBundleID: String) -> String {
        """
        identifier "\(appBundleID)" \
        and anchor apple generic \
        and certificate leaf[subject.OU] = "\(teamID)"
        """
    }
}

/// XPC interface implemented by the root helper and called by the app.
///
/// The helper runs as root (installed via `SMAppService`), so it can flip the
/// `SleepDisabled` flag without an admin prompt. A heartbeat watchdog inside the
/// helper auto-restores normal sleep if the app stops checking in — so the Mac
/// can never get stuck awake if the app crashes or is force-quit.
@objc public protocol LidlessHelperProtocol {
    /// Enable/disable lid-close sleep prevention. reply: (success, errorMessage?).
    func setKeepAwake(_ enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void)

    /// Read the current SleepDisabled flag. reply: (enabled).
    func getState(withReply reply: @escaping (Bool) -> Void)

    /// Heartbeat from the app; resets the watchdog timer.
    func heartbeat(withReply reply: @escaping (Bool) -> Void)

    /// Helper version string, for a connection sanity check.
    func version(withReply reply: @escaping (String) -> Void)

    /// Schedule a one-shot wake, replacing any wake this app already has.
    ///
    /// Replies with the date the helper **read back** out of the system after
    /// writing it, not the date it was handed: powerd stores these at one-second
    /// resolution and is the thing that decides what got scheduled. A reply of
    /// `(date, nil)` therefore means "this is on the machine, verified"; `(nil,
    /// message)` means it isn't. Contrast `setKeepAwake`, which has no value to
    /// report and so answers with a plain success flag.
    ///
    /// The owner id is **not** a parameter. The helper runs as root and this
    /// call leads to cancelling power events; letting a caller name which owner
    /// to act on would hand any client of the Mach service the ability to
    /// delete power events belonging to macOS or to the user. The helper
    /// derives its own id from `LIDLESS_MACH_LABEL` instead.
    func scheduleWake(at date: Date, withReply reply: @escaping (Date?, String?) -> Void)

    /// Remove every wake this app scheduled, and nothing else. Idempotent —
    /// succeeds when there was nothing to remove.
    ///
    /// These two calls are the whole interface, and between them they can
    /// express every repair the app needs. Leftovers the app spots while
    /// reconciling — a stale event powerd didn't purge, a duplicate from an
    /// interrupted write — are cleared by re-asserting the invariant with
    /// `scheduleWake(at:)` (which sweeps ours before writing) when a wake
    /// should still be pending, or by `cancelScheduledWake` when none should.
    /// There is no "cancel these specific dates" call because there is nothing
    /// it could do that those two can't.
    func cancelScheduledWake(withReply reply: @escaping (Bool, String?) -> Void)
}
