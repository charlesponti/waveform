import Foundation

private struct Summary {
  let processingSeconds: Double
  let callbackMicros: [Double]
  let emitted: Int
  let checksum: Double
}

private func signal(_ count: Int) -> [Float] {
  var state: UInt64 = 0x5eed_cafe_f00d
  return (0..<count).map { _ in
    state = state &* 6_364_136_223_846_793_005 &+ 1
    return Float(Double(Int32(bitPattern: UInt32(truncatingIfNeeded: state >> 32))) / Double(Int32.max) * 0.3)
  }
}

private func run(rate: Double, columnRate: Double, frames: Int, duration: Int, measureCallbacks: Bool) -> Summary {
  let timingGroupSize = 32
  let samples = signal(Int(rate) * duration)
  let windowBlocks = max(1, Int((0.025 * columnRate).rounded()))
  let builder = ColumnBuilder(sampleRate: rate, columnsPerSecond: columnRate, windowBlocks: windowBlocks)
  let ring = ColumnRing(capacity: Int(columnRate * 2))
  let chunks = (samples.count + frames - 1) / frames
  var times = measureCallbacks ? [Double](repeating: 0, count: (chunks + timingGroupSize - 1) / timingGroupSize) : []
  var checksum = 0.0
  let processingStart = DispatchTime.now().uptimeNanoseconds
  samples.withUnsafeBufferPointer { buffer in
    var start = 0
    var index = 0
    var groupStart: UInt64 = 0
    while start < samples.count {
      let count = min(frames, samples.count - start)
      let consume: (Column) -> Void = { column in
        ring.append(column)
        checksum += Double(column.low + column.high + column.rms + column.level)
      }
      if measureCallbacks {
        if index % timingGroupSize == 0 { groupStart = DispatchTime.now().uptimeNanoseconds }
        builder.feed(buffer.baseAddress! + start, count: count, emit: consume)
        if (index + 1) % timingGroupSize == 0 || start + count == samples.count {
          let groupCount = min(timingGroupSize, chunks - (index / timingGroupSize) * timingGroupSize)
          times[index / timingGroupSize] = Double(DispatchTime.now().uptimeNanoseconds - groupStart) / 1_000 / Double(groupCount)
        }
      } else {
        builder.feed(buffer.baseAddress! + start, count: count, emit: consume)
      }
      index += 1
      start += count
    }
  }
  precondition(ring.count == builder.columns)
  let processingSeconds = Double(DispatchTime.now().uptimeNanoseconds - processingStart) / 1_000_000_000
  return Summary(processingSeconds: processingSeconds, callbackMicros: times,
                 emitted: builder.columns, checksum: checksum)
}

private func percentile(_ values: [Double], _ p: Double) -> Double {
  let sorted = values.sorted()
  return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded(.up)))]
}

private func median(_ values: [Double]) -> Double {
  let sorted = values.sorted()
  return sorted[sorted.count / 2]
}

@main private enum StreamingCaptureBenchmark {
  static func main() {
    let duration = 60
    let repeats = 5
    let warmups = 1
    let sizes = [128, 256, 512, 1_024, 2_048]
    print("duration_seconds=\(duration) repeats=\(repeats) warmups=\(warmups)")
    print("columns_per_second is 120 at 48kHz (Waveform LiveInput default), 125 at 16kHz (prior comparison)")
    print("timing_window_callbacks=32 (group elapsed divided by callbacks)")
    print("CSV: rate_hz,chunk_frames,capture_interval_ms,callback_ms,cpu_percent,group_avg_feed_p50_us,p95_us,p99_us,max_us,retained_bytes,ring_capacity_columns")
    var aggregateChecksum = 0.0
    var profileChecksum = 0.0
    for (rate, columnRate) in [(48_000.0, 120.0), (16_000.0, 125.0)] {
      for frames in sizes {
        var elapsed: [Double] = []
        for iteration in 0..<(repeats + warmups) {
          let result = run(rate: rate, columnRate: columnRate, frames: frames, duration: duration, measureCallbacks: false)
          if iteration >= warmups {
            elapsed.append(result.processingSeconds)
            aggregateChecksum += result.checksum
          }
          precondition(result.emitted == Int(columnRate * Double(duration)))
        }
        let profiled = run(rate: rate, columnRate: columnRate, frames: frames, duration: duration, measureCallbacks: true)
        profileChecksum += profiled.checksum
        let ringCapacity = 1 << Int(ceil(log2(columnRate * 2)))
        let ringBytes = ringCapacity * MemoryLayout<Column>.stride
        let builderWindowBytes = max(1, Int((0.025 * columnRate).rounded())) * (MemoryLayout<Double>.stride + MemoryLayout<Int>.stride)
        let retainedBytes = ringBytes + builderWindowBytes
        let ms = median(elapsed) * 1_000
        let cpuPercent = ms / (Double(duration) * 1_000) * 100
        print(String(format: "%d,%d,%.3f,%.3f,%.5f,%.2f,%.2f,%.2f,%.2f,%d,%d",
                     Int(rate), frames, Double(frames) / rate * 1_000, ms, cpuPercent,
                     percentile(profiled.callbackMicros, 0.50), percentile(profiled.callbackMicros, 0.95),
                     percentile(profiled.callbackMicros, 0.99), profiled.callbackMicros.max() ?? 0,
                     retainedBytes, ringCapacity))
      }
    }
    print("checksum=\(aggregateChecksum) profile_checksum=\(profileChecksum)")
  }
}
