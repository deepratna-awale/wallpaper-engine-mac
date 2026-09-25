import Accelerate
import Foundation

/// Power spectrum of a complex DFT of any length, through Bluestein's chirp-z transform on vDSP's
/// power-of-two FFT. WE's audio block is 2089 samples at 48 kHz (`AudioSpectrumBlockTransform`),
/// which no vDSP DFT length covers.
///
/// X[k] = Σₙ x[n]·e^(−2πink/L) = w[k]·Σₙ (x[n]·w[n])·conj(w[k−n]) with w[m] = e^(−iπm²/L), so
/// |X[k]|² = |(a ⊛ b)[k]|² for a[n] = x[n]·w[n] and b[m] = conj(w[m]); the circular convolution runs
/// on a padded power-of-two FFT. Not thread-safe: one instance per thread (it owns its scratch).
final class BluesteinDFT {
    let length: Int
    private let paddedLength: Int
    private let log2Padded: vDSP_Length
    private let setup: FFTSetup
    private let chirpReal: [Float]
    private let chirpImaginary: [Float]
    private var kernelReal: [Float]
    private var kernelImaginary: [Float]
    private var workReal: [Float]
    private var workImaginary: [Float]

    init?(length: Int) {
        guard length > 1 else { return nil }
        var padded = 1
        while padded < 2 * length - 1 { padded <<= 1 }
        let log2Padded = vDSP_Length(padded.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2Padded, FFTRadix(kFFTRadix2)) else { return nil }
        self.length = length
        self.paddedLength = padded
        self.log2Padded = log2Padded
        self.setup = setup

        // w[n] = e^(−iπ n²/L); n² is reduced mod 2L in integers so the angle stays exact.
        var chirpReal = [Float](repeating: 0, count: length)
        var chirpImaginary = [Float](repeating: 0, count: length)
        for n in 0..<length {
            let phase = Double((n * n) % (2 * length)) * Double.pi / Double(length)
            chirpReal[n] = Float(cos(phase))
            chirpImaginary[n] = Float(-sin(phase))
        }
        self.chirpReal = chirpReal
        self.chirpImaginary = chirpImaginary

        // b[m] = conj(w[m]) for m in −(L−1)…(L−1), wrapped into the padded length.
        kernelReal = [Float](repeating: 0, count: padded)
        kernelImaginary = [Float](repeating: 0, count: padded)
        for m in 0..<length {
            kernelReal[m] = chirpReal[m]
            kernelImaginary[m] = -chirpImaginary[m]
            if m > 0 {
                kernelReal[padded - m] = chirpReal[m]
                kernelImaginary[padded - m] = -chirpImaginary[m]
            }
        }
        workReal = [Float](repeating: 0, count: padded)
        workImaginary = [Float](repeating: 0, count: padded)
        Self.fft(setup, &kernelReal, &kernelImaginary, log2Padded, FFTDirection(FFT_FORWARD))
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Writes |X[k]|² for k in 0..<`power.count` (at most `length`) of the forward DFT of
    /// `real + i·imaginary`, both `length` long. Non-finite input propagates, as in any DFT.
    func powerSpectrum(real: [Float], imaginary: [Float], into power: inout [Float]) {
        precondition(real.count == length && imaginary.count == length, "BluesteinDFT input length")
        precondition(power.count <= length, "BluesteinDFT asked for more bins than it has")
        for n in 0..<length {
            let re = real[n], im = imaginary[n], wr = chirpReal[n], wi = chirpImaginary[n]
            workReal[n] = re * wr - im * wi
            workImaginary[n] = re * wi + im * wr
        }
        for n in length..<paddedLength {
            workReal[n] = 0
            workImaginary[n] = 0
        }
        Self.fft(setup, &workReal, &workImaginary, log2Padded, FFTDirection(FFT_FORWARD))
        for n in 0..<paddedLength {
            let re = workReal[n], im = workImaginary[n], kr = kernelReal[n], ki = kernelImaginary[n]
            workReal[n] = re * kr - im * ki
            workImaginary[n] = re * ki + im * kr
        }
        Self.fft(setup, &workReal, &workImaginary, log2Padded, FFTDirection(FFT_INVERSE))
        // vDSP's inverse is unnormalised: divide the convolution by the padded length.
        let scale = 1 / Float(paddedLength)
        for k in 0..<power.count {
            let re = workReal[k] * scale, im = workImaginary[k] * scale
            power[k] = re * re + im * im
        }
    }

    private static func fft(_ setup: FFTSetup, _ real: inout [Float], _ imaginary: inout [Float],
                            _ log2n: vDSP_Length, _ direction: FFTDirection) {
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2n, direction)
            }
        }
    }
}
