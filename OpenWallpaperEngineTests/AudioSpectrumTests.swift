import XCTest
@testable import OpenWallpaperEngine

final class AudioSpectrumTests: XCTestCase {
    private let sampleRate: Float = 48_000
    private let binWidth: Float = 48_000 / Float(AudioSpectrumAnalyzer.fftSize)

    private func sine(frequency: Float, amplitude: Float = 0.5, count: Int = 2048) -> [Float] {
        (0..<count).map { amplitude * sin(2 * .pi * frequency * Float($0) / sampleRate) }
    }

    private func feed(_ analyzer: AudioSpectrumAnalyzer, left: [Float], right: [Float]) {
        left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in analyzer.ingest(left: l, right: r) } }
    }

    private func settle(_ analyzer: AudioSpectrumAnalyzer) -> AudioSpectrumSnapshot {
        var snapshot = AudioSpectrumSnapshot.silent
        for _ in 0..<10 { snapshot = analyzer.advanceFrame() }
        return snapshot
    }

    func testSineLandsInExpectedBand() throws {
        let analyzer = AudioSpectrumAnalyzer()
        // 64-band b reads bin 2b; bin 20 → band 10. 32-band b reads bin 4b+2; bin 22 → band 5.
        let signal = zip(sine(frequency: 20 * binWidth), sine(frequency: 22 * binWidth)).map { $0 + $1 }
        feed(analyzer, left: signal, right: signal)
        let snapshot = settle(analyzer)
        XCTAssertEqual(snapshot.left64.firstIndex(of: snapshot.left64.max()!), 10)
        XCTAssertGreaterThan(snapshot.left64[10], 0.9)
        XCTAssertLessThan(snapshot.left64[20], 0.1)
        XCTAssertEqual(snapshot.left32.firstIndex(of: snapshot.left32.max()!), 5)
        XCTAssertGreaterThan(snapshot.left32[5], 0.9)
        XCTAssertEqual(snapshot.left16.count, 16)
    }

    func testLeftOnlyLeavesRightSilent() {
        let analyzer = AudioSpectrumAnalyzer()
        let signal = sine(frequency: 30 * binWidth)
        feed(analyzer, left: signal, right: [Float](repeating: 0, count: signal.count))
        let snapshot = settle(analyzer)
        XCTAssertGreaterThan(snapshot.left64.max()!, 0.5)
        for values in [snapshot.right16, snapshot.right32, snapshot.right64] {
            XCTAssertEqual(values.max()!, 0, accuracy: 1e-6)
        }
    }

    func testSmoothingLimitsPerFrameChange() {
        let analyzer = AudioSpectrumAnalyzer()
        let signal = sine(frequency: 20 * binWidth, amplitude: 1)
        feed(analyzer, left: signal, right: signal)
        var previous = analyzer.snapshot
        XCTAssertEqual(previous.left64[10], 0)
        for _ in 0..<5 {
            let next = analyzer.advanceFrame()
            for (a, b) in zip(previous.left64, next.left64) {
                XCTAssertLessThanOrEqual(abs(b - a), AudioSpectrumAnalyzer.maxStep + 1e-6)
            }
            previous = next
        }
        XCTAssertEqual(analyzer.snapshot.left64[10], 1, accuracy: 1e-6)
        analyzer.reset()
        XCTAssertEqual(analyzer.advanceFrame().left64[10], 0.7, accuracy: 1e-5)
    }

    func testSilenceIsZero() {
        let analyzer = AudioSpectrumAnalyzer()
        let silence = [Float](repeating: 0, count: 4096)
        feed(analyzer, left: silence, right: silence)
        XCTAssertEqual(settle(analyzer), .silent)
    }

    func testCurveMatchesLWE() {
        XCTAssertEqual(AudioSpectrumAnalyzer.tilt(band: 63, count: 64), 2 - exp(-0.5), accuracy: 1e-6)
        XCTAssertEqual(AudioSpectrumAnalyzer.tilt(band: 0, count: 16), 2 - exp(0.5), accuracy: 1e-6)
        XCTAssertEqual(AudioSpectrumAnalyzer.value(power: 100, band: 63, count: 64),
                       min(1, 0.7 * (2 - exp(-0.5))), accuracy: 1e-6)
        XCTAssertEqual(AudioSpectrumAnalyzer.value(power: 0, band: 3, count: 16), 0)
    }
}
