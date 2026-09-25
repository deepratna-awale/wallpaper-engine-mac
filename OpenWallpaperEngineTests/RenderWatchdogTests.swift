import XCTest
@testable import OpenWallpaperEngine

final class RenderWatchdogTests: XCTestCase {
    private final class Clock {
        var now: TimeInterval = 1000
    }

    private let thresholds = RenderWatchdog.Thresholds(gracePeriod: 20, mainThreadStall: 3,
                                                       slowFrameMedian: 0.25, frameWindow: 10,
                                                       minimumFrameSamples: 5, pollInterval: 0.5)

    private func makeWatchdog() -> (RenderWatchdog, Clock) {
        let clock = Clock()
        return (RenderWatchdog(thresholds: thresholds, clock: { clock.now }), clock)
    }

    /// Feeds frames of `duration` for `seconds`, evaluating after each one.
    private func run(_ watchdog: RenderWatchdog, _ clock: Clock, frames duration: TimeInterval,
                     for seconds: TimeInterval) -> RenderWatchdog.Trip? {
        let end = clock.now + seconds
        while clock.now < end {
            clock.now += max(duration, 1.0 / 60)
            watchdog.recordFrame(duration: duration)
            if let trip = watchdog.evaluate() { return trip }
        }
        return nil
    }

    func testDisarmedNeverTrips() {
        let (watchdog, clock) = makeWatchdog()
        XCTAssertFalse(watchdog.mainThreadPingSent())
        XCTAssertNil(run(watchdog, clock, frames: 1, for: 60))
    }

    func testSlowFramesDuringGraceDoNotTrip() {
        let (watchdog, clock) = makeWatchdog()
        watchdog.arm()
        XCTAssertNil(run(watchdog, clock, frames: 2, for: 19))
        XCTAssertNil(run(watchdog, clock, frames: 1.0 / 60, for: 30))
    }

    func testSustainedSlowFramesTripAfterTheWindow() {
        let (watchdog, clock) = makeWatchdog()
        watchdog.arm()
        clock.now += 20
        let start = clock.now
        let trip = run(watchdog, clock, frames: 0.3, for: 30)
        XCTAssertEqual(trip, .slowFrames(medianSeconds: 0.3))
        XCTAssertGreaterThanOrEqual(clock.now - start, 10)
        XCTAssertNil(watchdog.evaluate(), "a trip is reported once per arming")
    }

    func testOccasionalHitchesDoNotTrip() {
        let (watchdog, clock) = makeWatchdog()
        watchdog.arm()
        clock.now += 20
        for _ in 0..<600 {
            clock.now += 1.0 / 60
            watchdog.recordFrame(duration: 1.0 / 60)
            XCTAssertNil(watchdog.evaluate())
        }
        // A 1.5 s shader compile hitch in the middle of smooth frames.
        clock.now += 1.5
        watchdog.recordFrame(duration: 1.5)
        XCTAssertNil(watchdog.evaluate())
        XCTAssertNil(run(watchdog, clock, frames: 1.0 / 60, for: 15))
    }

    func testFewSamplesDoNotTrip() {
        let (watchdog, clock) = makeWatchdog()
        watchdog.arm()
        clock.now += 20
        for _ in 0..<4 {
            clock.now += 3
            watchdog.recordFrame(duration: 1)
        }
        XCTAssertNil(watchdog.evaluate())
    }

    func testMainThreadStallTripsPastTheLimit() {
        let (watchdog, clock) = makeWatchdog()
        watchdog.arm()
        clock.now += 20
        XCTAssertTrue(watchdog.mainThreadPingSent())
        XCTAssertFalse(watchdog.mainThreadPingSent(), "one ping in flight")
        clock.now += 2.9
        XCTAssertNil(watchdog.evaluate())
        clock.now += 0.2
        guard case .mainThreadStalled(let seconds) = watchdog.evaluate() else { return XCTFail("expected a stall") }
        XCTAssertEqual(seconds, 3.1, accuracy: 1e-6)
    }

    func testAnsweredPingsDoNotTrip() {
        let (watchdog, clock) = makeWatchdog()
        watchdog.arm()
        clock.now += 20
        for _ in 0..<100 {
            watchdog.mainThreadPingSent()
            clock.now += 1
            watchdog.mainThreadPongReceived()
            XCTAssertNil(watchdog.evaluate())
        }
    }

    func testStallDuringGraceCountsFromItsEnd() {
        let (watchdog, clock) = makeWatchdog()
        watchdog.arm()
        clock.now += 5
        watchdog.mainThreadPingSent()
        clock.now += 17 // 2 s past the grace period, 17 s since the ping.
        XCTAssertNil(watchdog.evaluate())
        clock.now += 1.5
        XCTAssertNotNil(watchdog.evaluate())
    }

    func testRearmingRestartsGrace() {
        let (watchdog, clock) = makeWatchdog()
        watchdog.arm()
        clock.now += 20
        XCTAssertNotNil(run(watchdog, clock, frames: 0.5, for: 30))
        watchdog.arm()
        XCTAssertNil(run(watchdog, clock, frames: 0.5, for: 19))
    }

    func testMedian() {
        XCTAssertEqual(RenderWatchdog.median([3, 1, 2]), 2)
        XCTAssertEqual(RenderWatchdog.median([4, 1, 2, 3]), 2.5)
        XCTAssertEqual(RenderWatchdog.median([]), 0)
    }
}
