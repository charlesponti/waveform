# Column methodology evaluation — results

Run date: 2026-10-23 (Europe/London)
Machine: MacBookPro18,4 · Apple M1 Max · arm64 · Swift 6.4
Command: `swiftc -O` compiling the benchmark with the actual WaveformCore `Column.swift` and `ColumnBuilder.swift`; executable placed in `/tmp`. No SwiftPM build, project test, or Waveform source edit.

## Setup

- Input: deterministic synthetic Float32 signal, 16 kHz, 60 seconds; 125 columns/s (7,500 columns).
- Settings: 25 ms rolling RMS window, 150 ms release; batch receives the full resident signal, streaming receives 512-frame (32 ms audio) chunks.
- Arms: scalar batch mirror of the React algorithm; batch arrays using Accelerate; actual WaveformCore `ColumnBuilder` streaming with an output checksum sink.
- Each process run: 3 warmups and 8 measured repetitions per arm. Three process runs; reported time is the median of their per-process medians. Streaming chunk latency was profiled separately over 5 passes.

## Results

| Method | Median processing time for 60 s input | Relative to Accelerate batch |
|---|---:|---:|
| Scalar batch mirror | 1.311 ms | 6.52× slower |
| Accelerate batch arrays | 0.201 ms | 1.00× |
| WaveformCore streaming builder | 0.422 ms | 2.10× slower |

The Accelerate batch arm processed the already-loaded buffer about 2.1× faster end to end in this test. The straightforward scalar batch mirror was slower than the streaming builder, showing that implementation/vectorization matters as much as the batch-versus-streaming shape.

Streaming `feed` chunk latency: p50 0.17 μs, p95 0.21 μs, p99 0.29 μs across the profiled chunks. One run saw a 29.58 μs maximum, consistent with a scheduler interruption; even that is far below the 32 ms audio chunk duration. These are processing times after each chunk is available, not the chunk's 32 ms capture/acquisition delay.

Batch output payload estimate: 120,000 bytes for four 7,500-element Float32 arrays, excluding allocator overhead. The streaming builder retains no output history; its downstream consumer storage (such as Waveform's ring) is excluded and is bounded by that consumer's configured capacity.

## Correctness preflight

All 7,500 output columns were compared component by component. Stream vs Accelerate batch had maximum absolute difference 0 for low/high/RMS/level at these aligned settings and 512-frame chunks. Scalar batch vs Accelerate batch had maximum component difference `1.4901161e-08`. This validates the benchmark cases; it is not a full unit-test run or proof across all sample rates, chunk sizes, or boundary conditions.

## Interpretation and limits

- **Offline throughput:** the Accelerate batch arm wins for a complete in-memory buffer, but returns arrays proportional to duration.
- **Live input:** streaming is the appropriate shape because it emits columns as chunks arrive and keeps builder state bounded; measured processing is negligible beside the 32 ms chunk cadence.
- This is a same-machine Swift methodology comparison. The scalar batch arm mirrors the React math but is not the actual JavaScript/V8 runtime, so these numbers do not establish whether JavaScript batch beats native Swift streaming.
- Synthetic input and a single production configuration (16 kHz/125 columns/s) were used. Run a second dataset/configuration only if a concrete consumer needs it.
- No tests/builds of the Waveform package were run. The only compilation was the standalone benchmark executable.
