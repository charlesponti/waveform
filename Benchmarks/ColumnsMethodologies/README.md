# Column methodology benchmark

This evaluation compares the existing WaveformCore streaming implementation with two batch implementations for the React helper's production settings: 16 kHz input, 125 columns/s, a 25 ms RMS window, and a 150 ms release.

- `streaming`: actual `ColumnBuilder`, fed 512-frame chunks; output columns are consumed in a checksum and not retained.
- `batch_accelerate`: whole-buffer Swift batch implementation using Accelerate reductions and four allocated output arrays.
- `batch_scalar`: whole-buffer Swift translation of the React algorithm's scalar loop and four output arrays.

The Accelerate batch arm and streaming arm use the same DSP primitives and settings; this is the closest methodology comparison. The scalar arm helps show the effect of a straightforward batch translation. All three are Swift on the same machine, so results do not compare JavaScript runtime performance with Swift performance. Output payload estimates exclude allocator overhead, builder state, and any downstream ring buffer. Streaming chunk latencies measure processing time per 512-frame feed call; they do not include the 32 ms audio acquisition interval.

For a separate live-capture comparison across 128–2,048 frame chunks at 48 kHz and 16 kHz, see [`streaming-capture-results.md`](streaming-capture-results.md). Its standalone harness is `StreamingCaptureBenchmark.swift`; it uses the actual `ColumnBuilder` and `ColumnRing` implementations.

Run these commands from the repository root on macOS:

```sh
swiftc -O -o /tmp/columns-methodology-benchmark Benchmarks/ColumnsMethodologies/Benchmark.swift \
  Sources/WaveformCore/Column.swift \
  Sources/WaveformCore/ColumnBuilder.swift
/tmp/columns-methodology-benchmark
```

The capture-size harness can be compiled the same way:

```sh
swiftc -O -o /tmp/streaming-capture-benchmark Benchmarks/ColumnsMethodologies/StreamingCaptureBenchmark.swift \
  Sources/WaveformCore/Column.swift \
  Sources/WaveformCore/ColumnBuilder.swift \
  Sources/WaveformCore/ColumnRing.swift
/tmp/streaming-capture-benchmark
```

These commands compile temporary executables and do not invoke SwiftPM. The first benchmark includes a correctness preflight, warmups, repeated timing, median total processing time, streaming chunk percentiles, real-time factor, and output payload estimate. The capture benchmark compares chunk sizes, group-averaged callback service times, CPU time, and bounded retained memory.
