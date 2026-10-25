# waveform 0.1.0

First release: an accurate voice waveform and an orb of dots that listens, for iOS 18 and macOS 15.

## What's in it

**WaveformCore** (no UI)
- `ColumnBuilder`: exact columns (`round(k * sampleRate / rate)`), windowed rms, and a level with instant attack and a release.
- `SpectrumBuilder`: a Hann-windowed FFT in 24 log-spaced bands. A sine of amplitude A reads A/sqrt(2); the band powers add up to the mean square.
- `ColumnRing` and `SpectrumRing`: lock-free hand-off from the audio thread to the screen.
- `StreamClock`, `Playhead`, `FrameClock`: draw each column at the moment it is heard, with a phase-locked loop on the frame times.
- `ColumnWindow` and `SpectrumWindow`: Catmull-Rom reads at a fractional position.
- `OrbModel`, `LiveInput` (microphone or file), `Synthesize` (repeatable test voices).

**WaveformUI** (SwiftUI)
- `SpectrumOrbView`: pitch round the sphere, time down it, loudness pushing dots out.
- `OrbView`: the orb with time only.
- `WaveformView`: scrolling bars.

## Quality

- 68 tests; 100% line coverage of both library targets, enforced in CI by `scripts/coverage.sh`.
- The one excluded line is the system microphone permission request (`SystemMicrophone.swift`).
- The audio tap is tested against a real `AVAudioEngine` in offline rendering mode.

## Install

```swift
.package(url: "https://github.com/charlesponti/waveform", from: "0.1.0")
```

Needs Swift 6.2. See the [README](https://github.com/charlesponti/waveform#readme) and the [live explainer](https://charlesponti.github.io/voice-orb/).
