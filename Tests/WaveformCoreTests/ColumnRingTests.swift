import Foundation
import Testing

@testable import WaveformCore

@Suite struct ColumnRingTests {
  private func column(_ i: Int) -> Column { Column(low: Float(i), high: Float(i), rms: Float(i)) }

  @Test func theNewestColumnsComeBackOldestFirst() {
    let ring = ColumnRing(capacity: 16)
    for i in 0..<100 { ring.append(column(i)) }
    var out = [Column](repeating: .silent, count: 5)
    let real = out.withUnsafeMutableBufferPointer { ring.copyLast(5, into: $0.baseAddress!) }
    #expect(real == 5)
    #expect(out.map(\.low) == [95, 96, 97, 98, 99])
  }

  @Test func earlyOnTheFrontIsSilent() {
    let ring = ColumnRing(capacity: 16)
    ring.append(column(1))
    ring.append(column(2))
    var out = [Column](repeating: column(9), count: 4)
    let real = out.withUnsafeMutableBufferPointer { ring.copyLast(4, into: $0.baseAddress!) }
    #expect(real == 2)
    #expect(out.map(\.low) == [0, 0, 1, 2])
  }

  /// A writer on another thread racing a reader: every copy must be a run of consecutive columns,
  /// never a torn mix of old and new.
  @Test func aReaderRacingAWriterNeverSeesATornRun() async {
    let ring = ColumnRing(capacity: 64)
    let total = 400_000
    let writer = Task.detached {
      for i in 0..<total { ring.append(Column(low: Float(i), high: Float(i), rms: Float(i))) }
    }
    var out = [Column](repeating: .silent, count: 32)
    var bad = 0
    var reads = 0
    while ring.count < total {
      let real = out.withUnsafeMutableBufferPointer { ring.copyLast(32, into: $0.baseAddress!) }
      reads += 1
      if real == 32 {
        for i in 1..<32 where out[i].low != out[i - 1].low + 1 { bad += 1 }
      }
    }
    await writer.value
    #expect(bad == 0, "\(bad) torn reads in \(reads)")
  }
}

@Suite struct RingRetryTests {
  @Test func aColumnCopyLappedByTheWriterIsThrownAwayAndRedone() {
    let ring = ColumnRing(capacity: 8)
    for i in 0..<8 { ring.append(Column(low: Float(i), high: 0, rms: 0)) }
    var laps = 0
    ring.afterCopy = {
      guard laps == 0 else { return }
      laps += 1
      for i in 8..<24 { ring.append(Column(low: Float(i), high: 0, rms: 0)) }  // the writer laps the reader
    }
    var out = [Column](repeating: .silent, count: 4)
    let (real, end) = out.withUnsafeMutableBufferPointer { ring.snapshot(4, into: $0.baseAddress!) }
    #expect(laps == 1)
    #expect(real == 4 && end == 24)
    #expect(out.map(\.low) == [20, 21, 22, 23])  // the second, whole copy
  }

  @Test func aSpectrumCopyLappedByTheWriterIsThrownAwayAndRedone() {
    let ring = SpectrumRing(bands: 2, capacity: 8)
    func frame(_ i: Int) -> [Float] { [Float(i), Float(-i)] }
    for i in 0..<8 { frame(i).withUnsafeBufferPointer { ring.append($0) } }
    var laps = 0
    ring.afterCopy = {
      guard laps == 0 else { return }
      laps += 1
      for i in 8..<24 { frame(i).withUnsafeBufferPointer { ring.append($0) } }
    }
    var out = [Float](repeating: 0, count: 8)
    let (real, end) = out.withUnsafeMutableBufferPointer { ring.snapshot(4, into: $0.baseAddress!) }
    #expect(laps == 1 && real == 4 && end == 24)
    #expect(out == [20, -20, 21, -21, 22, -22, 23, -23])
  }
}
