import XCTest
import IOKit.pwr_mgt

/// Tests for the pure scheduled-wake logic.
///
/// The fixtures deliberately mirror what a real Mac returns: the two
/// `com.apple.alarm.user-invisible-*` events below are copied from actual
/// `pmset -g sched` output on a machine with nothing unusual configured. They
/// are here because the single worst outcome this feature could have is
/// cancelling a power event that isn't ours, and a test using only our own
/// events would never catch it.
final class ScheduledWakeTests: XCTestCase {

    // MARK: Fixtures

    private let owner = "com.nghialuong.lidless.dev.wake"

    private func event(at date: Date,
                       owner: String,
                       type: String = kIOPMAutoWake) -> [String: Any] {
        [
            kIOPMPowerEventTimeKey: date,
            kIOPMPowerEventAppNameKey: owner,
            kIOPMPowerEventTypeKey: type
        ]
    }

    /// Events macOS itself schedules — observed verbatim on a real machine.
    private func systemEvents(now: Date) -> [[String: Any]] {
        [
            event(at: now.addingTimeInterval(600),
                  owner: "com.apple.alarm.user-invisible-com.apple.calaccessd.travelEngine.periodicRefreshTimer"),
            event(at: now.addingTimeInterval(60_000),
                  owner: "com.apple.alarm.user-invisible-com.apple.osanalytics.hardhighengagementtimer")
        ]
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: Owner id

    func testOwnerIDFromMachLabelReplacesHelperSuffix() {
        XCTAssertEqual(ScheduledWake.ownerID(fromMachLabel: "com.nghialuong.lidless.dev.helper"),
                       "com.nghialuong.lidless.dev.wake")
        XCTAssertEqual(ScheduledWake.ownerID(fromMachLabel: "com.nghialuong.lidless.helper"),
                       "com.nghialuong.lidless.wake")
    }

    /// An unexpected label must still produce a distinctive id. Returning an
    /// empty string would make the owner filter match nothing (feature dead) or,
    /// worse, match loosely.
    func testOwnerIDFromMachLabelWithoutHelperSuffixAppends() {
        XCTAssertEqual(ScheduledWake.ownerID(fromMachLabel: "com.example.thing"),
                       "com.example.thing.wake")
        XCTAssertEqual(ScheduledWake.ownerID(fromMachLabel: ""), ".wake")
    }

    /// The helper derives the id from its Mach label; the app derives it from
    /// its bundle id. If those two ever disagree, the app reads a schedule it
    /// cannot see and reports "no wake scheduled" while one is pending.
    func testOwnerIDFromBundleIDMatchesMachLabelDerivation() {
        let bundleID = "com.nghialuong.lidless.dev"
        let machLabel = LidlessHelper.label(appBundleID: bundleID)
        XCTAssertEqual(ScheduledWake.ownerID(appBundleID: bundleID),
                       ScheduledWake.ownerID(fromMachLabel: machLabel))
    }

    func testOwnerIDMatchesReleaseAndDebugSeparately() {
        XCTAssertNotEqual(ScheduledWake.ownerID(appBundleID: "com.nghialuong.lidless"),
                          ScheduledWake.ownerID(appBundleID: "com.nghialuong.lidless.dev"))
    }

    // MARK: Wake date

    func testWakeDateAddsRequestedMinutes() {
        XCTAssertEqual(ScheduledWake.wakeDate(from: t0, minutes: 15),
                       t0.addingTimeInterval(900))
        XCTAssertEqual(ScheduledWake.wakeDate(from: t0, minutes: 240),
                       t0.addingTimeInterval(14_400))
    }

    /// powerd stores whole seconds; truncating up front is what lets the
    /// read-back check be an exact comparison instead of a fuzzy one.
    func testWakeDateTruncatesToWholeSecond() {
        let fractional = Date(timeIntervalSince1970: 1_000_000.75)
        let result = ScheduledWake.wakeDate(from: fractional, minutes: 1)
        XCTAssertEqual(result.timeIntervalSince1970, 1_000_060, accuracy: 0.0001)
    }

    // MARK: Filtering — the promise not to touch anyone else's events

    func testOwnedWakeDatesIgnoresForeignOwners() {
        let ours = t0.addingTimeInterval(900)
        let events = systemEvents(now: t0) + [event(at: ours, owner: owner)]
        XCTAssertEqual(ScheduledWake.ownedWakeDates(events: events, ownerID: owner), [ours])
    }

    func testOwnedWakeDatesReturnsNothingWhenOnlyForeignEventsExist() {
        XCTAssertTrue(ScheduledWake.ownedWakeDates(events: systemEvents(now: t0),
                                                   ownerID: owner).isEmpty)
    }

    /// A sleep or power-on event carrying our owner id is not a wake we
    /// scheduled, and must not be counted as one — nor cancelled as one.
    func testOwnedWakeDatesIgnoresNonWakeEventTypes() {
        let events = [
            event(at: t0.addingTimeInterval(900), owner: owner, type: "sleep"),
            event(at: t0.addingTimeInterval(1800), owner: owner, type: kIOPMAutoPowerOn),
            event(at: t0.addingTimeInterval(2700), owner: owner, type: kIOPMAutoWakeOrPowerOn)
        ]
        XCTAssertTrue(ScheduledWake.ownedWakeDates(events: events, ownerID: owner).isEmpty)
    }

    func testOwnedWakeDatesSkipsEntryMissingKeys() {
        let events: [[String: Any]] = [
            [kIOPMPowerEventAppNameKey: owner, kIOPMPowerEventTypeKey: kIOPMAutoWake],  // no time
            [kIOPMPowerEventTimeKey: t0, kIOPMPowerEventTypeKey: kIOPMAutoWake],        // no owner
            [kIOPMPowerEventTimeKey: t0, kIOPMPowerEventAppNameKey: owner],             // no type
            [:]
        ]
        XCTAssertTrue(ScheduledWake.ownedWakeDates(events: events, ownerID: owner).isEmpty)
    }

    /// Same rule `PowerParsers` follows: data of an unexpected shape says
    /// nothing, so it must not be defaulted into "this one is ours".
    func testOwnedWakeDatesSkipsEntryWithWrongTypes() {
        let events: [[String: Any]] = [
            [kIOPMPowerEventTimeKey: "12/25/26 09:00:00",
             kIOPMPowerEventAppNameKey: owner,
             kIOPMPowerEventTypeKey: kIOPMAutoWake],
            [kIOPMPowerEventTimeKey: t0,
             kIOPMPowerEventAppNameKey: 42,
             kIOPMPowerEventTypeKey: kIOPMAutoWake],
            [kIOPMPowerEventTimeKey: t0,
             kIOPMPowerEventAppNameKey: owner,
             kIOPMPowerEventTypeKey: 7]
        ]
        XCTAssertTrue(ScheduledWake.ownedWakeDates(events: events, ownerID: owner).isEmpty)
    }

    func testOwnedWakeDatesReturnsAscendingOrder() {
        let later = t0.addingTimeInterval(1800)
        let sooner = t0.addingTimeInterval(600)
        let events = [event(at: later, owner: owner), event(at: sooner, owner: owner)]
        XCTAssertEqual(ScheduledWake.ownedWakeDates(events: events, ownerID: owner),
                       [sooner, later])
    }

    func testOwnedWakeDatesEmptyForEmptyInput() {
        XCTAssertTrue(ScheduledWake.ownedWakeDates(events: [], ownerID: owner).isEmpty)
    }

    // MARK: pendingWake — what the machine will actually do next

    func testPendingWakeReturnsEarliestFutureNotLatest() {
        let sooner = t0.addingTimeInterval(600)
        let later = t0.addingTimeInterval(1800)
        let events = [event(at: later, owner: owner), event(at: sooner, owner: owner)]
        XCTAssertEqual(ScheduledWake.pendingWake(events: events, ownerID: owner, now: t0), sooner)
    }

    func testPendingWakeIgnoresPastEventsAndPicksNextFuture() {
        let past = t0.addingTimeInterval(-600)
        let future = t0.addingTimeInterval(600)
        let events = [event(at: past, owner: owner), event(at: future, owner: owner)]
        XCTAssertEqual(ScheduledWake.pendingWake(events: events, ownerID: owner, now: t0), future)
    }

    func testPendingWakeNilWhenAllEventsPast() {
        let events = [event(at: t0.addingTimeInterval(-600), owner: owner)]
        XCTAssertNil(ScheduledWake.pendingWake(events: events, ownerID: owner, now: t0))
    }

    /// The moment has arrived, so the event has fired. A countdown of exactly
    /// zero is not something to render.
    func testPendingWakeAtExactlyNowIsNotPending() {
        let events = [event(at: t0, owner: owner)]
        XCTAssertNil(ScheduledWake.pendingWake(events: events, ownerID: owner, now: t0))
    }

    func testPendingWakeNilWhenOnlyForeignEventsPending() {
        XCTAssertNil(ScheduledWake.pendingWake(events: systemEvents(now: t0),
                                               ownerID: owner, now: t0))
    }

    // MARK: staleWakeDates — cleanup, with a grace window

    /// Just-fired events belong to powerd for a moment; cancelling one mid-purge
    /// is a race we simply decline to enter.
    func testStaleWakeDatesExcludesWithinGraceWindow() {
        let justFired = t0.addingTimeInterval(-30)
        let events = [event(at: justFired, owner: owner)]
        XCTAssertTrue(ScheduledWake.staleWakeDates(events: events, ownerID: owner, now: t0).isEmpty)
    }

    func testStaleWakeDatesIncludesBeyondGrace() {
        let old = t0.addingTimeInterval(-90)
        let events = [event(at: old, owner: owner)]
        XCTAssertEqual(ScheduledWake.staleWakeDates(events: events, ownerID: owner, now: t0), [old])
    }

    func testStaleWakeDatesBoundaryIsInclusiveAtExactlyGrace() {
        let exactly = t0.addingTimeInterval(-60)
        let events = [event(at: exactly, owner: owner)]
        XCTAssertEqual(ScheduledWake.staleWakeDates(events: events, ownerID: owner, now: t0),
                       [exactly])
    }

    func testStaleWakeDatesExcludesFutureEvents() {
        let events = [event(at: t0.addingTimeInterval(900), owner: owner)]
        XCTAssertTrue(ScheduledWake.staleWakeDates(events: events, ownerID: owner, now: t0).isEmpty)
    }

    func testStaleWakeDatesNeverIncludesForeignEvents() {
        let ancient = t0.addingTimeInterval(-9999)
        let events = [
            event(at: ancient, owner: "com.apple.alarm.user-invisible-something"),
            event(at: ancient, owner: "pmset")
        ]
        XCTAssertTrue(ScheduledWake.staleWakeDates(events: events, ownerID: owner, now: t0).isEmpty)
    }

    // MARK: surplusWakeDates — duplicates get cancelled, earliest survives

    func testSurplusWakeDatesReturnsAllButEarliest() {
        let a = t0.addingTimeInterval(600)
        let b = t0.addingTimeInterval(1200)
        let c = t0.addingTimeInterval(1800)
        let events = [event(at: c, owner: owner), event(at: a, owner: owner), event(at: b, owner: owner)]
        XCTAssertEqual(ScheduledWake.surplusWakeDates(events: events, ownerID: owner, now: t0), [b, c])
    }

    func testSurplusWakeDatesEmptyForSingleEvent() {
        let events = [event(at: t0.addingTimeInterval(600), owner: owner)]
        XCTAssertTrue(ScheduledWake.surplusWakeDates(events: events, ownerID: owner, now: t0).isEmpty)
    }

    func testSurplusWakeDatesIgnoresPastEvents() {
        let past = t0.addingTimeInterval(-600)
        let future = t0.addingTimeInterval(600)
        let events = [event(at: past, owner: owner), event(at: future, owner: owner)]
        XCTAssertTrue(ScheduledWake.surplusWakeDates(events: events, ownerID: owner, now: t0).isEmpty)
    }

    func testSurplusWakeDatesNeverIncludesForeignEvents() {
        let events = systemEvents(now: t0) + [event(at: t0.addingTimeInterval(60), owner: owner)]
        XCTAssertTrue(ScheduledWake.surplusWakeDates(events: events, ownerID: owner, now: t0).isEmpty)
    }

    // MARK: Helper capability gate

    func testHelperSupportsScheduledWakeAcceptsEqualAndNewer() {
        XCTAssertTrue(ScheduledWake.helperSupportsScheduledWake(version: "0.2.0"))
        XCTAssertTrue(ScheduledWake.helperSupportsScheduledWake(version: "0.2.1"))
        XCTAssertTrue(ScheduledWake.helperSupportsScheduledWake(version: "0.3"))
        XCTAssertTrue(ScheduledWake.helperSupportsScheduledWake(version: "1.0.0"))
    }

    func testHelperSupportsScheduledWakeRejectsOlder() {
        XCTAssertFalse(ScheduledWake.helperSupportsScheduledWake(version: "0.1.0"))
        XCTAssertFalse(ScheduledWake.helperSupportsScheduledWake(version: "0.1.9"))
        XCTAssertFalse(ScheduledWake.helperSupportsScheduledWake(version: "0"))
    }

    /// An unreadable version is not evidence the helper can do this. Guessing
    /// "yes" recreates the six-second hang the gate exists to prevent.
    func testHelperSupportsScheduledWakeRejectsUnparseableInput() {
        XCTAssertFalse(ScheduledWake.helperSupportsScheduledWake(version: ""))
        XCTAssertFalse(ScheduledWake.helperSupportsScheduledWake(version: "abc"))
        XCTAssertFalse(ScheduledWake.helperSupportsScheduledWake(version: "0.2.0-beta"))
        XCTAssertFalse(ScheduledWake.helperSupportsScheduledWake(version: "0..2"))
        XCTAssertFalse(ScheduledWake.helperSupportsScheduledWake(version: "-1.0.0"))
    }

    // MARK: Shared presets and formatting

    func testEventTypeIsWakeNotWakeOrPowerOn() {
        XCTAssertEqual(ScheduledWake.eventType, "wake")
        XCTAssertNotEqual(ScheduledWake.eventType, kIOPMAutoWakeOrPowerOn)
    }

    func testPresetsContainTheStandardDurations() {
        for minutes in DurationFormat.standardMinutes {
            XCTAssertTrue(ScheduledWake.presetMinutes.contains(minutes),
                          "missing preset \(minutes)")
        }
    }

    /// Release builds must not offer the one-minute test affordance.
    func testOneMinutePresetIsDebugOnly() {
        #if DEBUG
        XCTAssertEqual(ScheduledWake.presetMinutes.first, 1)
        #else
        XCTAssertFalse(ScheduledWake.presetMinutes.contains(1))
        #endif
    }

    func testFormattingMatchesAutoOff() {
        XCTAssertEqual(ScheduledWake.formatCountdown(3909), AutoOff.formatCountdown(3909))
        XCTAssertEqual(ScheduledWake.optionLabel(minutes: 60), AutoOff.optionLabel(minutes: 60))
    }

    func testRemainingClampsToZero() {
        XCTAssertEqual(ScheduledWake.remaining(until: t0.addingTimeInterval(-10), now: t0), 0)
        XCTAssertEqual(ScheduledWake.remaining(until: t0.addingTimeInterval(90), now: t0), 90)
    }
}
