import Synchronization

/// The newest spectrum frames, handed from the audio thread to the screen without a lock. The same
/// idea as `ColumnRing`, with `bands` numbers in each slot.
public final class SpectrumRing: @unchecked Sendable {
  public let bands: Int
  public let capacity: Int
  /// Runs between copying and checking whether the writer lapped the copy; for tests only.
  var afterCopy: (() -> Void)?
  private let slots: UnsafeMutablePointer<Float>
  private let mask: Int
  private let written = Atomic<Int>(0)

  public init(bands: Int, capacity: Int) {
    var size = 1
    while size < max(2, capacity) { size <<= 1 }
    self.bands = bands
    self.capacity = size
    mask = size - 1
    slots = .allocate(capacity: size * bands)
    slots.initialize(repeating: 0, count: size * bands)
  }

  deinit { slots.deallocate() }

  public var count: Int { written.load(ordering: .acquiring) }

  /// Called by the one writer: `values` holds `bands` numbers.
  public func append(_ values: UnsafeBufferPointer<Float>) {
    let index = written.load(ordering: .relaxed)
    (slots + (index & mask) * bands).update(from: values.baseAddress!, count: bands)
    written.store(index + 1, ordering: .releasing)
  }

  /// Copies the newest `n` frames into `out` (`n * bands` numbers), oldest first, with silence in front
  /// when there are fewer. Returns how many are real and the total written, so `out`'s frame 0 is
  /// absolute frame `end - n`. Called by the one reader.
  @discardableResult
  public func snapshot(_ n: Int, into out: UnsafeMutablePointer<Float>) -> (real: Int, end: Int) {
    let n = min(n, capacity - 1)
    var end = 0
    var real = 0
    // If the writer moved on far enough to overwrite what was copied, copy again.
    repeat {
      end = written.load(ordering: .acquiring)
      real = min(n, end)
      if real < n { out.update(repeating: 0, count: (n - real) * bands) }
      for i in 0..<real {
        (out + (n - real + i) * bands).update(from: slots + ((end - real + i) & mask) * bands, count: bands)
      }
      afterCopy?()
    } while written.load(ordering: .acquiring) - (end - real) > capacity
    return (real, end)
  }
}

/// A stretch of spectrum frames copied from the ring, read at any fractional time and pitch.
/// Time is by absolute frame index; between frames it follows a Catmull-Rom curve (smooth, no corners).
/// Pitch is a band coordinate from 0 (the lowest band) to `bands - 1`; between bands it is a straight
/// blend, because neighbouring bands are one musical step apart.
public struct SpectrumWindow {
  public let values: UnsafeBufferPointer<Float>
  public let bands: Int
  public let base: Int

  public init(values: UnsafeBufferPointer<Float>, bands: Int, base: Int) {
    self.values = values
    self.bands = bands
    self.base = base
  }

  /// Display height (0...1) at absolute frame `position` and band coordinate `band`.
  public func value(time position: Double, band: Float, scale: Scale) -> Float {
    let frames = values.count / bands
    guard frames > 0 else { return 0 }
    let local = position - Double(base)
    let i = Int(local.rounded(.down))
    let t = Float(local - Double(i))
    let lowBand = max(0, min(bands - 1, Int(band)))
    let highBand = min(bands - 1, lowBand + 1)
    let mix = max(0, min(1, band - Float(lowBand)))
    func along(_ b: Int) -> Float {
      func at(_ k: Int) -> Float {
        scale.height(values[max(0, min(frames - 1, k)) * bands + b])
      }
      return ColumnWindow.catmullRom(at(i - 1), at(i), at(i + 1), at(i + 2), t)
    }
    let low = along(lowBand)
    let high = lowBand == highBand ? low : along(highBand)
    return max(0, low * (1 - mix) + high * mix)
  }
}
