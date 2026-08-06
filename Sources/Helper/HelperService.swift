import Foundation

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: LidlessHelperProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

/// The actual privileged work. Runs as root, so it can call `pmset` directly
/// with no admin prompt. Guards against a stuck-awake state with a watchdog.
final class HelperService: NSObject, LidlessHelperProtocol {
    private let queue = DispatchQueue(label: "com.nghialuong.lidless.helper.state")
    private var lastHeartbeat = Date()
    private var keepAwake = false
    private let watchdogTimeout: TimeInterval = 90
    private var watchdogTimer: DispatchSourceTimer?

    override init() {
        super.init()
        startWatchdog()
    }

    // MARK: LidlessHelperProtocol

    func setKeepAwake(_ enabled: Bool, withReply reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            let result = self.runPmset(disableSleep: enabled)
            if result.ok {
                self.keepAwake = enabled
                self.lastHeartbeat = Date()
            }
            reply(result.ok, result.error)
        }
    }

    func getState(withReply reply: @escaping (Bool) -> Void) {
        let out = Self.capture("/usr/bin/pmset", ["-g"]) ?? ""
        reply(PowerParsers.isSleepDisabled(pmsetG: out))
    }

    func heartbeat(withReply reply: @escaping (Bool) -> Void) {
        queue.async {
            self.lastHeartbeat = Date()
            reply(true)
        }
    }

    func version(withReply reply: @escaping (String) -> Void) {
        reply("0.2.0")
    }

    // MARK: Scheduled wake

    /// The owner id stamped onto every power event this helper creates, derived
    /// from our own launchd label rather than accepted from the caller — see
    /// the note on `scheduleWake` in `LidlessHelperProtocol`. Debug and Release
    /// have different labels, so their wakes can't see or cancel each other's.
    private lazy var wakeOwnerID: String = {
        let label = ProcessInfo.processInfo.environment[LidlessHelper.machLabelEnvKey]
            ?? LidlessHelper.fallbackLabel
        return ScheduledWake.ownerID(fromMachLabel: label)
    }()

    func scheduleWake(at date: Date, withReply reply: @escaping (Date?, String?) -> Void) {
        queue.async {
            // Drop any sub-second part before writing. This is an entry point,
            // so it can't assume the caller already did — and a fractional date
            // would schedule successfully, come back from powerd rounded, and
            // then fail the check below for a wake that really is on the Mac.
            let target = ScheduledWake.wholeSecond(date)
            // Clear ours first, then write. The ordering is what makes an
            // interrupted call safe: if this process dies between the two
            // steps the machine is left with no wake at all, which is a Mac
            // that quietly doesn't wake up. The other order would leave two,
            // which is a Mac that wakes at a time nothing ever told the user
            // about — much harder to notice and much harder to explain.
            if let error = self.clearOwnedWakes() {
                reply(nil, error)
                return
            }
            let status = WakeScheduler.schedule(target, ownerID: self.wakeOwnerID)
            guard status == kIOReturnSuccess else {
                reply(nil, WakeScheduler.describe(status))
                return
            }
            // Read back rather than trust the return code: a success status
            // says the call was accepted, not that the machine now holds this
            // event. Same rule the app follows after `setKeepAwake`.
            guard let events = WakeScheduler.copyEvents() else {
                reply(nil, "Couldn’t read the wake schedule back.")
                return
            }
            let ours = ScheduledWake.ownedWakeDates(events: events, ownerID: self.wakeOwnerID)
            // Exactly one, at the time we asked for — the invariant this whole
            // method exists to maintain, checked against the machine rather
            // than assumed from a return code.
            guard ours.count == 1, let scheduled = ours.first,
                  ScheduledWake.isSameWakeInstant(scheduled, target) else {
                reply(nil, "The wake time didn’t take effect.")
                return
            }
            // Reply with what powerd holds, not with what we were handed.
            // powerd decides what got scheduled; echoing the input back would
            // report agreement we never actually checked for.
            reply(scheduled, nil)
        }
    }

    func cancelScheduledWake(withReply reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            if let error = self.clearOwnedWakes() {
                reply(false, error)
                return
            }
            reply(true, nil)
        }
    }

    /// Cancel every wake carrying our owner id, then confirm none remain.
    /// Returns nil on success, or a message describing what went wrong.
    ///
    /// Only ever passes dates that `ownedWakeDates` attributed to us, so a
    /// power event belonging to macOS or to the user is never an argument to
    /// `IOPMCancelScheduledPowerEvent`. Must be called on `queue`.
    private func clearOwnedWakes() -> String? {
        guard let events = WakeScheduler.copyEvents() else {
            return "Couldn’t read the wake schedule."
        }
        for date in ScheduledWake.ownedWakeDates(events: events, ownerID: wakeOwnerID) {
            let status = WakeScheduler.cancel(date, ownerID: wakeOwnerID)
            guard status == kIOReturnSuccess || status == kIOReturnNotFound else {
                return WakeScheduler.describe(status)
            }
        }
        guard let after = WakeScheduler.copyEvents() else {
            return "Couldn’t read the wake schedule back."
        }
        guard ScheduledWake.ownedWakeDates(events: after, ownerID: wakeOwnerID).isEmpty else {
            return "A previous wake time couldn’t be cleared."
        }
        return nil
    }

    // MARK: Watchdog

    /// Restores normal sleep when the app stops checking in.
    ///
    /// Scheduled wakes are deliberately outside its remit. The watchdog exists
    /// because a Mac stuck awake is a Mac cooking itself in a bag; a pending
    /// wake has no such failure mode, and the whole point of handing the
    /// deadline to powerd is that it outlives the app. Clearing it here would
    /// mean an alarm the user set silently evaporates because they quit a
    /// menu-bar app.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.keepAwake else { return }
            if Watchdog.shouldAutoRestore(lastHeartbeat: self.lastHeartbeat,
                                          now: Date(),
                                          timeout: self.watchdogTimeout) {
                _ = self.runPmset(disableSleep: false)
                self.keepAwake = false
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    // MARK: Shell

    @discardableResult
    private func runPmset(disableSleep: Bool) -> (ok: Bool, error: String?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        proc.arguments = ["-a", "disablesleep", disableSleep ? "1" : "0"]
        let errPipe = Pipe()
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            return (false, error.localizedDescription)
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (false, msg.isEmpty ? "pmset exited \(proc.terminationStatus)" : msg)
        }
        return (true, nil)
    }

    private static func capture(_ path: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}
