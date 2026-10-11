# waveform-ios

An accurate voice waveform, and an orb of dots that listens, for iOS and macOS. Time runs from the equator of the
sphere to the poles, pitch runs round it, and loudness pushes each dot out. The React half is
[waveform-react](https://github.com/charlesponti/waveform-react), and
[the explainer](https://charlesponti.github.io/voice-orb/) walks through the maths with live demos.

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/charlesponti/waveform-ios", from: "0.1.0")
// and in your target:
.product(name: "WaveformUI", package: "waveform-ios")   // or "WaveformCore"
```

Two libraries: `WaveformCore` (no UI: the maths, the rings, the clocks, the microphone) and `WaveformUI`
(SwiftUI views). Needs iOS 18 or macOS 15, Swift 6.2.

## Use

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

Add `NSMicrophoneUsageDescription` to your Info.plist. A refused microphone throws
`LiveInput.MicrophoneError.denied` instead of quietly delivering silence.

| View | What it draws |
| --- | --- |
| `WaveformView` | The newest columns scrolling in from the right: lowest to highest sample, and loudness. |
| `OrbView` | The orb with time only: loudness pushes dots out. |
| `SpectrumOrbView` | The orb with pitch round the sphere and time down it. |

To drive a view without a microphone, fill a ring yourself with `ColumnBuilder` or `SpectrumBuilder`, or play a
file with `LiveInput.play(file:)`.

## Why it is accurate

- Column edges are `round(k · sampleRate / rate)`, so an odd rate cannot drift.
- Loudness is rms over a 25 ms window with instant attack and a 150 ms release, in decibels.
- A pure tone of amplitude A reads A/√2 in its spectrum band, and the band powers add up to the signal's mean
  square. Both are tests.
- The audio thread writes into lock-free rings and never allocates; the screen reads on its own clock.
- Pictures run a fixed 60 ms behind the audio on the audio's own clock, smoothed by a phase-locked loop on the
  frame times and a Catmull-Rom curve between columns.

## Tests

```bash
swift test
./scripts/coverage.sh   # fails below 100% line coverage of WaveformCore and WaveformUI
```

Everything in the two library targets is covered, except one line that raises the system microphone dialog
(`SystemMicrophone.swift`). The audio tap is tested against a real `AVAudioEngine` in offline rendering mode.

## Demo app

```bash
swift run -c release WaveformApp          # live microphone, three looks
swift run -c release WaveformApp --spectrum-snapshot out.png
```

## License

MIT
