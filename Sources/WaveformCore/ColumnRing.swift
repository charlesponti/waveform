import Synchronization

/// The newest columns, handed from the audio thread to the screen without a lock.
///
/// One thread writes (`append`) and one reads (`copyLast`). The writer stores a column and then
/// publishes the new count with release ordering; the reader loads the count with acquire ordering,
/// so it never sees a column that is not finished. If the writer laps the reader mid-copy, the copy
/// is thrown away and tried again, so what is drawn is never torn.
public final class ColumnRing: @unchecked Sendable {
  private let slots: UnsafeMutablePointer<Column>
  private let mask: Int
  private let written = Atomic<Int>(0)
  public let capacity: Int
  /// Runs between copying and checking whether the writer lapped the copy. Tests use it to be the
  /// writer at exactly that moment; nothing else sets it.
  var afterCopy: (() -> Void)?

  /// `capacity` is rounded up to a power of two.
  public init(capacity: Int) {
    var size = 1
    while size < max(2, capacity) { size <<= 1 }
    self.capacity = size
    mask = size - 1
    slots = .allocate(capacity: size)
    slots.initialize(repeating: .silent, count: size)
  }

  deinit {
    slots.deallocate()
  }

  /// Total columns ever written.
  public var count: Int { written.load(ordering: .acquiring) }

  /// Called by the one writer.
  public func append(_ column: Column) {
    let index = written.load(ordering: .relaxed)
    slots[index & mask] = column
    written.store(index + 1, ordering: .releasing)
  }

  /// Copies the newest `n` columns into `out`, oldest first (fewer than `n` early on: the front of `out`
  /// is left silent). Returns how many are real and the total written when the copy was made, so the
  /// caller knows the absolute index of each column: `out[n - real]` is column `end - real`.
  /// Called by the one reader.
  @discardableResult
  public func snapshot(_ n: Int, into out: UnsafeMutablePointer<Column>) -> (real: Int, end: Int) {
    let n = min(n, capacity - 1)
    var end = 0
    var real = 0
    // If the writer moved on far enough to overwrite what was copied, copy again.
    repeat {
      end = written.load(ordering: .acquiring)
      real = min(n, end)
      for i in 0..<(n - real) { out[i] = .silent }
      for i in 0..<real { out[n - real + i] = slots[(end - real + i) & mask] }
      afterCopy?()
    } while written.load(ordering: .acquiring) - (end - real) > capacity
    return (real, end)
  }

  /// The same, returning only how many are real.
  @discardableResult
  public func copyLast(_ n: Int, into out: UnsafeMutablePointer<Column>) -> Int {
    snapshot(n, into: out).real
  }
}
