import Accelerate
import Foundation

/// Turns audio into a spectrum at a steady rate: for each hop, how loud the sound is in each of a few
/// bands of pitch, from low to high.
///
/// The bands are evenly spaced on a log scale (so each is the same musical width), from `lowHz` to
/// `highHz`. Each hop looks at the last `fftSize` samples through a Hann window. A band's value is the
/// RMS amplitude of the sound inside it: an in-band sine shows approximately as A / sqrt(2), and the
/// bands' squares sum to the mean square of the in-range test tone. Frequencies outside the configured
/// range are omitted. Hops land on whole samples exactly as `ColumnBuilder`'s do, so frame k and column k
/// describe the same moment.
///
/// It never allocates after `init`, so it is safe on the audio thread.
public final class SpectrumBuilder {
  public let sampleRate: Double
  public let columnsPerSecond: Double
  public let fftSize: Int
  public let bands: Int
  public let lowHz: Double
  public let highHz: Double
  /// Display tilt: speech spectra often fall by roughly 6 dB per octave or more, so without a lift the
  /// high bands can sit near silence. Added to each band as `tilt` dB per octave above 1 kHz; 0 disables it.
  public let tiltDBPerOctave: Double

  private var seen = 0
  private var emitted = 0
  private var nextEdge: Int
  private let history: UnsafeMutablePointer<Float>
  private var writeIndex = 0
  private let linear: UnsafeMutablePointer<Float>
  private let window: UnsafeMutablePointer<Float>
  private let real: UnsafeMutablePointer<Float>
  private let imag: UnsafeMutablePointer<Float>
  private let power: UnsafeMutablePointer<Float>
  private let cumulative: UnsafeMutablePointer<Float>
  private let output: UnsafeMutablePointer<Float>
  private let binEdges: [Double]  // band edges, in bins
  private let tiltGain: [Float]  // power gain per band
  private let norm: Float
  private let log2n: vDSP_Length
  private let setup: FFTSetup

  public init(
    sampleRate: Double, columnsPerSecond: Double = 120, fftSize: Int = 2048, bands: Int = 24,
    lowHz: Double = 80, highHz: Double = 8_000, tiltDBPerOctave: Double = 3
  ) {
    precondition(fftSize >= 64 && fftSize & (fftSize - 1) == 0)
    precondition(highHz <= sampleRate / 2 && lowHz > 0 && lowHz < highHz && bands >= 2)
    self.sampleRate = sampleRate
    self.columnsPerSecond = columnsPerSecond
    self.fftSize = fftSize
    self.bands = bands
    self.lowHz = lowHz
    self.highHz = highHz
    self.tiltDBPerOctave = tiltDBPerOctave
    let half = fftSize / 2
    history = .allocate(capacity: fftSize)
    history.initialize(repeating: 0, count: fftSize)
    linear = .allocate(capacity: fftSize)
    window = .allocate(capacity: fftSize)
    real = .allocate(capacity: half)
    imag = .allocate(capacity: half)
    power = .allocate(capacity: half)
    cumulative = .allocate(capacity: half + 1)
    output = .allocate(capacity: bands)
    vDSP_hann_window(window, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
    var sumOfSquares: Float = 0
    vDSP_svesq(window, 1, &sumOfSquares, vDSP_Length(fftSize))
    // vDSP's real FFT returns twice the true value: |out|² / 4 is |X|², and 2|X|² / (N Σw²) is power.
    norm = 1 / (2 * Float(fftSize) * sumOfSquares)
    log2n = vDSP_Length(log2(Double(fftSize)))
    setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    let ratio = highHz / lowHz
    let edgesHz = (0...bands).map { lowHz * pow(ratio, Double($0) / Double(bands)) }
    binEdges = edgesHz.map { $0 * Double(fftSize) / sampleRate }
    tiltGain = (0..<bands).map { band in
      let centre = (edgesHz[band] * edgesHz[band + 1]).squareRoot()
      return Float(pow(10, tiltDBPerOctave * log2(centre / 1_000) / 10))
    }
    nextEdge = Int((sampleRate / columnsPerSecond).rounded())
  }

  deinit {
    for pointer in [history, linear, window, real, imag, power, cumulative, output] {
      pointer.deallocate()
    }
    vDSP_destroy_fftsetup(setup)
  }

  public var samplesSeen: Int { seen }
  public var frames: Int { emitted }

  /// Feeds `count` samples. `emit` is called with `bands` values for each hop that ends inside them.
  public func feed(
    _ samples: UnsafePointer<Float>, count: Int, emit: (UnsafeBufferPointer<Float>) -> Void
  ) {
    var offset = 0
    while offset < count {
      let take = min(count - offset, max(1, nextEdge - seen))
      store(samples + offset, take)
      seen += take
      offset += take
      if seen >= nextEdge {
        analyse()
        emit(UnsafeBufferPointer(start: output, count: bands))
        emitted += 1
        nextEdge = Int((Double(emitted + 1) * sampleRate / columnsPerSecond).rounded())
      }
    }
  }

  private func store(_ samples: UnsafePointer<Float>, _ count: Int) {
    var done = 0
    while done < count {
      let room = min(count - done, fftSize - writeIndex)
      (history + writeIndex).update(from: samples + done, count: room)
      writeIndex = (writeIndex + room) % fftSize
      done += room
    }
  }

  private func analyse() {
    let n = fftSize
    let half = n / 2
    // The last N samples, oldest first (anything before the start of the stream is zero).
    let tail = n - writeIndex
    linear.update(from: history + writeIndex, count: tail)
    (linear + tail).update(from: history, count: writeIndex)
    vDSP_vmul(linear, 1, window, 1, linear, 1, vDSP_Length(n))

    var split = DSPSplitComplex(realp: real, imagp: imag)
    linear.withMemoryRebound(to: DSPComplex.self, capacity: half) {
      vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
    }
    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
    vDSP_zvmags(&split, 1, power, 1, vDSP_Length(half))
    power[0] = 0  // DC and Nyquist share bin 0 in this layout; neither is in any band
    var scale = norm
    vDSP_vsmul(power, 1, &scale, power, 1, vDSP_Length(half))

    cumulative[0] = 0
    for k in 0..<half { cumulative[k + 1] = cumulative[k] + power[k] }

    // Power in each band, with the fraction of a bin that a band edge cuts through counted as such.
    for band in 0..<bands {
      let inBand = cumulativePower(upTo: binEdges[band + 1]) - cumulativePower(upTo: binEdges[band])
      output[band] = (max(0, inBand) * tiltGain[band]).squareRoot()
    }
  }

  /// Power of all bins below bin coordinate `x`, where bin k spans k - 0.5 to k + 0.5.
  private func cumulativePower(upTo x: Double) -> Float {
    let u = max(0, x + 0.5)
    let i = min(fftSize / 2 - 1, Int(u))
    return cumulative[i] + power[i] * Float(min(1, u - Double(i)))
  }
}
