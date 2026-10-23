import Accelerate
import Foundation

private struct BatchResult {
  let low: [Float]
  let high: [Float]
  let rms: [Float]
  let level: [Float]
  let checksum: Double
}

private struct RunResult {
  let elapsedSeconds: Double
  let emitted: Int
  let checksum: Double
  let chunkMicros: [Double]
}

@inline(never)
private func batchScalar(
  _ samples: [Float], sampleRate: Double, columnsPerSecond: Double,
  windowSeconds: Double, releaseSeconds: Double
) -> BatchResult {
  let n = Int(floor(Double(samples.count) * columnsPerSecond / sampleRate))
  let windowBlocks = max(1, Int((windowSeconds * columnsPerSecond).rounded()))
  var low = [Float](repeating: 0, count: n)
  var high = [Float](repeating: 0, count: n)
  var rms = [Float](repeating: 0, count: n)
  var level = [Float](repeating: 0, count: n)
  var squares = [Double](repeating: 0, count: windowBlocks)
  var counts = [Int](repeating: 0, count: windowBlocks)
  let decay = exp(-1 / (columnsPerSecond * max(releaseSeconds, 1e-6)))
  var previousLevel = 0.0
  var start = 0
  var checksum = 0.0

  for k in 0..<n {
    let end = Int((Double(k + 1) * sampleRate / columnsPerSecond).rounded())
    var lo = Float.infinity
    var hi = -Float.infinity
    var sum = 0.0
    for i in start..<end {
      let value = samples[i]
      lo = min(lo, value)
      hi = max(hi, value)
      let x = Double(value)
      sum += x * x
    }
    let slot = k % windowBlocks
    squares[slot] = sum
    counts[slot] = end - start
    let totalSquares = squares.reduce(0, +)
    let totalSamples = counts.reduce(0, +)
    let currentRMS = sqrt(totalSquares / Double(max(1, totalSamples)))
    previousLevel = max(currentRMS, previousLevel * decay)
    low[k] = lo
    high[k] = hi
    rms[k] = Float(currentRMS)
    level[k] = Float(previousLevel)
    checksum += Double(lo) + Double(hi) + currentRMS + previousLevel
    start = end
  }
  return BatchResult(low: low, high: high, rms: rms, level: level, checksum: checksum)
}

@inline(never)
private func batchAccelerate(
  _ samples: [Float], sampleRate: Double, columnsPerSecond: Double,
  windowSeconds: Double, releaseSeconds: Double
) -> BatchResult {
  let n = Int(floor(Double(samples.count) * columnsPerSecond / sampleRate))
  let windowBlocks = max(1, Int((windowSeconds * columnsPerSecond).rounded()))
  var low = [Float](repeating: 0, count: n)
  var high = [Float](repeating: 0, count: n)
  var rms = [Float](repeating: 0, count: n)
  var level = [Float](repeating: 0, count: n)
  var squares = [Double](repeating: 0, count: windowBlocks)
  var counts = [Int](repeating: 0, count: windowBlocks)
  let decay = Float(exp(-1 / (columnsPerSecond * max(releaseSeconds, 1e-6))))
  var previousLevel: Float = 0
  var start = 0
  var checksum = 0.0

  samples.withUnsafeBufferPointer { source in
    for k in 0..<n {
      let end = Int((Double(k + 1) * sampleRate / columnsPerSecond).rounded())
      let count = end - start
      let slice = source.baseAddress! + start
      var lo: Float = 0
      var hi: Float = 0
      var sum: Float = 0
      vDSP_minv(slice, 1, &lo, vDSP_Length(count))
      vDSP_maxv(slice, 1, &hi, vDSP_Length(count))
      vDSP_svesq(slice, 1, &sum, vDSP_Length(count))
      let slot = k % windowBlocks
      squares[slot] = Double(sum)
      counts[slot] = count
      var totalSquares = 0.0
      var totalSamples = 0
      for j in 0..<windowBlocks {
        totalSquares += squares[j]
        totalSamples += counts[j]
      }
      let currentRMS = Float((totalSquares / Double(max(1, totalSamples))).squareRoot())
      previousLevel = max(currentRMS, previousLevel * decay)
      low[k] = lo
      high[k] = hi
      rms[k] = currentRMS
      level[k] = previousLevel
      checksum += Double(lo) + Double(hi) + Double(currentRMS) + Double(previousLevel)
      start = end
    }
  }
  return BatchResult(low: low, high: high, rms: rms, level: level, checksum: checksum)
}

@inline(never)
private func streaming(
  _ samples: [Float], sampleRate: Double, columnsPerSecond: Double,
  windowSeconds: Double, releaseSeconds: Double, chunkSize: Int,
  captureChunkLatencies: Bool
) -> RunResult {
  let builder = ColumnBuilder(
    sampleRate: sampleRate,
    columnsPerSecond: columnsPerSecond,
    windowBlocks: max(1, Int((windowSeconds * columnsPerSecond).rounded())),
    releaseSeconds: releaseSeconds
  )
  var emitted = 0
  var checksum = 0.0
  let numberOfChunks = (samples.count + chunkSize - 1) / chunkSize
  var chunkMicros = captureChunkLatencies ? [Double](repeating: 0, count: numberOfChunks) : []
  samples.withUnsafeBufferPointer { source in
    var start = 0
    var chunkIndex = 0
    while start < samples.count {
      let count = min(chunkSize, samples.count - start)
      let emit: (Column) -> Void = { column in
        emitted += 1
        checksum += Double(column.low) + Double(column.high) + Double(column.rms) + Double(column.level)
      }
      if captureChunkLatencies {
        let began = DispatchTime.now().uptimeNanoseconds
        builder.feed(source.baseAddress! + start, count: count, emit: emit)
        let ended = DispatchTime.now().uptimeNanoseconds
        chunkMicros[chunkIndex] = Double(ended - began) / 1_000
      } else {
        builder.feed(source.baseAddress! + start, count: count, emit: emit)
      }
      chunkIndex += 1
      start += count
    }
  }
  return RunResult(elapsedSeconds: 0, emitted: emitted, checksum: checksum, chunkMicros: chunkMicros)
}

private func collectStreaming(
  _ samples: [Float], sampleRate: Double, columnsPerSecond: Double,
  windowSeconds: Double, releaseSeconds: Double, chunkSize: Int
) -> [Column] {
  let builder = ColumnBuilder(
    sampleRate: sampleRate,
    columnsPerSecond: columnsPerSecond,
    windowBlocks: max(1, Int((windowSeconds * columnsPerSecond).rounded())),
    releaseSeconds: releaseSeconds
  )
  var output: [Column] = []
  samples.withUnsafeBufferPointer { source in
    var start = 0
    while start < samples.count {
      let count = min(chunkSize, samples.count - start)
      builder.feed(source.baseAddress! + start, count: count) { output.append($0) }
      start += count
    }
  }
  return output
}

private func elapsed<T>(_ operation: () -> T) -> (T, Double) {
  let start = DispatchTime.now().uptimeNanoseconds
  let result = operation()
  let end = DispatchTime.now().uptimeNanoseconds
  return (result, Double(end - start) / 1_000_000_000)
}

private func observe(_ result: BatchResult) -> Double {
  var value = result.checksum
  for i in result.low.indices {
    value += Double(result.low[i]) * 0.000001
    value += Double(result.high[i]) * 0.000002
    value += Double(result.rms[i]) * 0.000003
    value += Double(result.level[i]) * 0.000004
  }
  return value
}

private func median(_ values: [Double]) -> Double {
  let sorted = values.sorted()
  return sorted[sorted.count / 2]
}

private func percentile(_ values: [Double], _ p: Double) -> Double {
  let sorted = values.sorted()
  return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

private func makeSignal(count: Int) -> [Float] {
  var state: UInt64 = 0x5eed_cafe_f00d
  return (0..<count).map { _ in
    state = state &* 6_364_136_223_846_793_005 &+ 1
    let signed = Double(Int32(bitPattern: UInt32(truncatingIfNeeded: state >> 32))) / Double(Int32.max)
    return Float(signed * 0.35)
  }
}

@main
private enum Benchmark {
  static func main() {
    let sampleRate = 16_000.0
    let columnsPerSecond = 125.0
    let windowSeconds = 0.025
    let releaseSeconds = 0.15
    let chunkSize = 512
    let duration = 60
    let repetitions = 11
    let warmups = 3
    let latencyProbes = 5
    let samples = makeSignal(count: Int(sampleRate) * duration)

    let reference = batchAccelerate(
      samples, sampleRate: sampleRate, columnsPerSecond: columnsPerSecond,
      windowSeconds: windowSeconds, releaseSeconds: releaseSeconds)
    let scalar = batchScalar(
      samples, sampleRate: sampleRate, columnsPerSecond: columnsPerSecond,
      windowSeconds: windowSeconds, releaseSeconds: releaseSeconds)
    let firstStream = streaming(
      samples, sampleRate: sampleRate, columnsPerSecond: columnsPerSecond,
      windowSeconds: windowSeconds, releaseSeconds: releaseSeconds, chunkSize: chunkSize,
      captureChunkLatencies: false)
    let capturedStream = collectStreaming(
      samples, sampleRate: sampleRate, columnsPerSecond: columnsPerSecond,
      windowSeconds: windowSeconds, releaseSeconds: releaseSeconds, chunkSize: chunkSize)
    let expectedCount = Int(floor(Double(samples.count) * columnsPerSecond / sampleRate))
    let scalarError = max(
      zip(reference.low, scalar.low).map { abs($0 - $1) }.max() ?? 0,
      zip(reference.high, scalar.high).map { abs($0 - $1) }.max() ?? 0,
      zip(reference.rms, scalar.rms).map { abs($0 - $1) }.max() ?? 0,
      zip(reference.level, scalar.level).map { abs($0 - $1) }.max() ?? 0)
    let streamError = max(
      zip(reference.low, capturedStream).map { abs($0 - $1.low) }.max() ?? 0,
      zip(reference.high, capturedStream).map { abs($0 - $1.high) }.max() ?? 0,
      zip(reference.rms, capturedStream).map { abs($0 - $1.rms) }.max() ?? 0,
      zip(reference.level, capturedStream).map { abs($0 - $1.level) }.max() ?? 0)
    guard reference.low.count == expectedCount, firstStream.emitted == expectedCount,
      capturedStream.count == expectedCount, scalar.low.count == expectedCount,
      scalarError < 0.00001, streamError < 0.00001
    else {
      fputs("Correctness preflight failed.\n", stderr)
      exit(2)
    }

    var scalarTimes: [Double] = []
    var acceleratedBatchTimes: [Double] = []
    var streamingTimes: [Double] = []
    var chunkTimes: [Double] = []
    var streamingChecksum = firstStream.checksum
    var outputDigest = 0.0
    for run in 0..<repetitions {
      let (scalarResult, scalarElapsed) = elapsed {
        batchScalar(samples, sampleRate: sampleRate, columnsPerSecond: columnsPerSecond,
                    windowSeconds: windowSeconds, releaseSeconds: releaseSeconds)
      }
      let (acceleratedResult, batchElapsed) = elapsed {
        batchAccelerate(samples, sampleRate: sampleRate, columnsPerSecond: columnsPerSecond,
                        windowSeconds: windowSeconds, releaseSeconds: releaseSeconds)
      }
      let digest = observe(scalarResult) + observe(acceleratedResult)
      let (streamResult, streamElapsed) = elapsed {
        streaming(samples, sampleRate: sampleRate, columnsPerSecond: columnsPerSecond,
                  windowSeconds: windowSeconds, releaseSeconds: releaseSeconds, chunkSize: chunkSize,
                  captureChunkLatencies: false)
      }
      if run >= warmups {
        outputDigest += digest
        scalarTimes.append(scalarElapsed)
        acceleratedBatchTimes.append(batchElapsed)
        streamingTimes.append(streamElapsed)
        streamingChecksum = streamResult.checksum
      }
    }

    var latencyProfile = firstStream
    for _ in 0..<latencyProbes {
      latencyProfile = streaming(
        samples, sampleRate: sampleRate, columnsPerSecond: columnsPerSecond,
        windowSeconds: windowSeconds, releaseSeconds: releaseSeconds, chunkSize: chunkSize,
        captureChunkLatencies: true)
      chunkTimes.append(contentsOf: latencyProfile.chunkMicros)
    }
    let columns = expectedCount
    let batchOutputBytes = columns * MemoryLayout<Float>.size * 4
    print("sample_rate_hz=\(Int(sampleRate)) columns_per_second=\(Int(columnsPerSecond)) duration_seconds=\(duration)")
    print("columns=\(columns) chunk_frames=\(chunkSize) chunk_audio_ms=\(Double(chunkSize) / sampleRate * 1000)")
    print("warmups=\(warmups) measured_repetitions=\(repetitions - warmups) latency_probes=\(latencyProbes) seed=0x5eedcafef00d")
    print("correctness_preflight=PASS max_component_error_scalar_vs_accelerate=\(scalarError) max_component_error_stream_vs_accelerate=\(streamError)")
    print(String(format: "batch_scalar_median_ms=%.3f", median(scalarTimes) * 1000))
    print(String(format: "batch_accelerate_median_ms=%.3f", median(acceleratedBatchTimes) * 1000))
    print(String(format: "streaming_median_ms=%.3f", median(streamingTimes) * 1000))
    print(String(format: "streaming_chunk_us_p50=%.2f p95=%.2f p99=%.2f max=%.2f",
                 percentile(chunkTimes, 0.50), percentile(chunkTimes, 0.95), percentile(chunkTimes, 0.99), chunkTimes.max() ?? 0))
    print(String(format: "realtime_factor_batch_accelerate=%.1fx streaming=%.1fx",
                 Double(duration) / median(acceleratedBatchTimes), Double(duration) / median(streamingTimes)))
    print("batch_output_payload_bytes_estimate=\(batchOutputBytes) streaming_builder_retained_output_bytes=0 (consumer storage excluded)")
    print("output_digest=\(outputDigest) stream_checksum=\(streamingChecksum) latency_profile_columns=\(latencyProfile.emitted)")
  }
}
