# waveform

[![CI](https://github.com/charlesponti/waveform/actions/workflows/ci.yml/badge.svg)](https://github.com/charlesponti/waveform/actions/workflows/ci.yml)
[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fcharlesponti%2Fwaveform%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/charlesponti/waveform)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fcharlesponti%2Fwaveform%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/charlesponti/waveform)
![Line coverage](https://img.shields.io/badge/line%20coverage-100%25-brightgreen)
[![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)

An accurate voice waveform, and an orb of dots that listens, for iOS and macOS.

![The orb at four moments of a synthetic voice](docs/orb.png)

Time runs from the equator of the sphere to the poles, pitch runs round it, and loudness pushes each dot out.
A hum lights one side, a whistle the other, a hiss the whole high side, and a drum makes rings that spread from the
equator. [Live demo and explainer](https://charlesponti.github.io/voice-orb/) · React version:
[waveform-react](https://github.com/charlesponti/waveform-react).

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/charlesponti/waveform", from: "0.1.0")
```

then, in your target:

```swift
.product(name: "WaveformUI", package: "waveform")     // SwiftUI views (includes Core)
.product(name: "WaveformCore", package: "waveform")   // no UI: the maths, rings, clocks, microphone
```

Needs iOS 18 or macOS 15 and Swift 6.2. Add `NSMicrophoneUsageDescription` to your Info.plist if you use the
microphone.

## Quick start

```swift
import SwiftUI
import WaveformCore
import WaveformUI

struct Listening: View {
  @State private var input = LiveInput(ring: ColumnRing(capacity: 4096))

  var body: some View {
    SpectrumOrbView(spectrum: input.spectrum, clock: input.clock)
      .task { try? await input.startMicrophone() }
  }
}
```

A refused microphone throws `LiveInput.MicrophoneError.denied` instead of quietly delivering silence. To try it
without a microphone, play a file with `input.play(file:)`, or fill a ring yourself with `ColumnBuilder` or
`SpectrumBuilder`.

## Views (`WaveformUI`)

| View | What it draws | Main parameters |
| --- | --- | --- |
| `SpectrumOrbView` | Pitch round the sphere, time down it, loudness pushing dots out | `spectrum`, `clock`, `gain`, `historySeconds`, `dotCount`, `turning` |
| `OrbView` | The orb with time only | `ring`, `clock`, `gain`, `historySeconds`, `dotCount`, `turning` |
| `WaveformView` | Columns scrolling in from the right: lowest to highest sample, and loudness | `ring`, `scale`, `barWidth`, `gap` |

All three take `showStats` (a corner readout of what a frame costs) and draw with four fills a frame however many
dots there are.

## Building blocks (`WaveformCore`)

| Type | Job |
| --- | --- |
| `ColumnBuilder` | Cuts audio into exact columns: lowest, highest, windowed rms, and a level with attack and release |
| `SpectrumBuilder` | A Hann-windowed FFT folded into log-spaced bands; a sine of amplitude A reads A/√2 |
| `ColumnRing`, `SpectrumRing` | Lock-free hand-off from the audio thread to the screen |
| `StreamClock`, `Playhead`, `FrameClock` | Draw each column at the moment it is heard, smoothed by a phase-locked loop |
| `ColumnWindow`, `SpectrumWindow` | Read the ring at a fractional position with a Catmull-Rom curve |
| `OrbModel` | The Fibonacci sphere: each dot's age (latitude) and pitch (longitude) |
| `LiveInput` | The microphone, or a file, into both rings |
| `Synthesize` | Repeatable synthetic voices for tests and pictures |

## Why it is accurate

- Column edges are `round(k · sampleRate / rate)`, so an odd rate cannot drift.
- Loudness is rms over a 25 ms window with instant attack and a 150 ms release, in decibels.
- Band powers add up to the signal's mean square. Both that and A/√2 are tests.
- The audio thread writes into lock-free rings and never allocates.
- Pictures run a fixed 60 ms behind the audio on the audio's own clock.

The [explainer](https://charlesponti.github.io/voice-orb/) shows each step with a live demo, starting from the
one-number orb that does not work.

## Tests

```bash
swift test
./scripts/coverage.sh   # fails below 100% line coverage of WaveformCore and WaveformUI
```

All 784 lines of the two library targets are covered, except the single line that raises the system microphone
dialog (`SystemMicrophone.swift`). The audio tap is tested against a real `AVAudioEngine` in offline rendering mode.

## Demo app

```bash
swift run -c release WaveformApp                           # live microphone, three looks
swift run -c release WaveformApp --spectrum-snapshot out.png
```

## Releases

See [CHANGELOG.md](CHANGELOG.md) and the [releases page](https://github.com/charlesponti/waveform/releases).

## License

MIT
