# Streaming capture chunk-size evaluation

## Question

How do audio callback chunk sizes affect WaveformCore's streaming `ColumnBuilder` under a sustained audio stream, considering processing CPU, callback cost, update latency, and retained memory?

## Method

- Compiled a standalone optimized Swift executable against the existing `Column`, `ColumnBuilder`, and `ColumnRing` source files. No SwiftPM build, test run, or source checkout edits were performed.
- Fed deterministic synthetic Float32 audio for 60 seconds through the actual `ColumnBuilder`, appending emitted columns to a two-second `ColumnRing` as `LiveInput` does.
- Compared chunk sizes of 128, 256, 512, 1,024, and 2,048 frames.
- Evaluated both 48 kHz / 120 columns per second (the `LiveInput` default) and 16 kHz / 125 columns per second (the previous methodology benchmark configuration).
- For each configuration, performed one warmup and five timed runs. Callback percentiles came from an additional instrumented pass. To reduce timer overhead, elapsed time was measured over groups of 32 callbacks and divided by 32; percentiles are group-average feed service times, separate from total CPU estimates.
- CPU percent is single-core processing wall time divided by 60 seconds of audio. It excludes audio hardware, AVAudioEngine, spectrum generation, UI drawing, and OS scheduling.
- Retained memory is a structural estimate: `ColumnRing`'s allocated `Column` slots plus the builder's rolling RMS window. It excludes object/allocator overhead, audio buffers owned by AVFoundation, and the app's other state. The ring rounds up to a power-of-two capacity and stores about two seconds of columns.

## Results

### 48 kHz input, 120 columns/s

| Frames | Audio per callback | CPU processing per 60 s | Estimated CPU | Group-average feed p50 / p95 / p99 | Retained estimate |
|---:|---:|---:|---:|---:|---:|
| 128 | 2.67 ms | 2.439 ms | 0.00406% | 0.10 / 0.14 / 0.16 µs | 4,144 B |
| 256 | 5.33 ms | 1.177 ms | 0.00196% | 0.10 / 0.11 / 0.11 µs | 4,144 B |
| 512 | 10.67 ms | 0.809 ms | 0.00135% | 0.15 / 0.18 / 0.42 µs | 4,144 B |
| 1,024 | 21.33 ms | 0.693 ms | 0.00115% | 0.25 / 0.26 / 0.37 µs | 4,144 B |
| 2,048 | 42.67 ms | 0.603 ms | 0.00101% | 0.43 / 0.46 / 1.39 µs | 4,144 B |

### 16 kHz input, 125 columns/s

| Frames | Audio per callback | CPU processing per 60 s | Estimated CPU | Group-average feed p50 / p95 / p99 | Retained estimate |
|---:|---:|---:|---:|---:|---:|
| 128 | 8 ms | 0.603 ms | 0.00101% | 0.08 / 0.09 / 0.09 µs | 4,144 B |
| 256 | 16 ms | 0.447 ms | 0.00074% | 0.12 / 0.12 / 0.29 µs | 4,144 B |
| 512 | 32 ms | 0.364 ms | 0.00061% | 0.20 / 0.21 / 0.27 µs | 4,144 B |
| 1,024 | 64 ms | 0.315 ms | 0.00052% | 0.34 / 0.36 / 0.37 µs | 4,144 B |
| 2,048 | 128 ms | 0.290 ms | 0.00048% | 0.63 / 0.65 / 0.65 µs | 4,144 B |

The largest observed callback in the instrumented pass was 34.67 µs; the 48 kHz / 2,048-frame row shows that scheduling noise can also affect p95/p99. These callback tails are still far below the corresponding 2.7–128 ms audio acquisition intervals, but a synthetic benchmark does not establish a real-time deadline guarantee.

## Interpretation

- **CPU:** Larger chunks reduce repeated `feed` call overhead, but the whole 128-to-2,048 frame range takes well under 2 ms of measured CPU per minute of audio on this machine. The savings are not a useful reason to increase capture latency in this workload.
- **Latency:** A column can only be finalized once its ending sample arrives. In a callback-fed design, an emitted column therefore waits up to roughly one callback interval for input, plus callback processing. At 48 kHz, the existing 512-frame tap represents about 10.7 ms; 2,048 frames represents about 42.7 ms. At 16 kHz, those intervals are 32 and 128 ms.
- **Memory:** The builder's state and the two-second display ring do not grow with input duration or callback size. The measured structural estimate is constant at 4,144 bytes for these settings. Streaming remains bounded-state; the ring is the intentional retained history.
- **Practical point:** Keep the platform-selected capture buffer when possible. If choosing a buffer size directly, 512 frames is a reasonable latency/overhead balance for 48 kHz voice visualization; 1,024–2,048 frames save negligible CPU and make visual updates coarser. This benchmark does not measure audio quality, missed callbacks, power draw, or AVAudioEngine's actual scheduling behavior.

## Reproduction

```sh
swiftc -O -o /tmp/streaming-capture-benchmark Benchmarks/ColumnsMethodologies/StreamingCaptureBenchmark.swift \
  Sources/WaveformCore/Column.swift \
  Sources/WaveformCore/ColumnBuilder.swift \
  Sources/WaveformCore/ColumnRing.swift
/tmp/streaming-capture-benchmark
```

The run used optimized Swift compilation on an Apple M1 Max with Swift 6.4 (2026-10-23). Raw CSV-like output is preserved below.

```text
duration_seconds=60 repeats=5 warmups=1
columns_per_second is 120 at 48kHz (Waveform LiveInput default), 125 at 16kHz (prior comparison)
timing_window_callbacks=32 (group elapsed divided by callbacks)
CSV: rate_hz,chunk_frames,capture_interval_ms,callback_ms,cpu_percent,group_avg_feed_p50_us,p95_us,p99_us,max_us,retained_bytes,ring_capacity_columns
48000,128,2.667,2.439,0.00406,0.10,0.14,0.16,0.74,4144,256
48000,256,5.333,1.177,0.00196,0.10,0.11,0.11,0.18,4144,256
48000,512,10.667,0.809,0.00135,0.15,0.18,0.42,0.73,4144,256
48000,1024,21.333,0.693,0.00115,0.25,0.26,0.37,0.37,4144,256
48000,2048,42.667,0.603,0.00101,0.43,0.46,1.39,1.39,4144,256
16000,128,8.000,0.603,0.00101,0.08,0.09,0.09,0.69,4144,256
16000,256,16.000,0.447,0.00074,0.12,0.12,0.29,0.35,4144,256
16000,512,32.000,0.364,0.00061,0.20,0.21,0.27,0.27,4144,256
16000,1024,64.000,0.315,0.00052,0.34,0.36,0.37,0.37,4144,256
16000,2048,128.000,0.290,0.00048,0.63,0.65,0.65,0.65,4144,256
checksum=127299.98673468828 profile_checksum=25459.997346937656
```
