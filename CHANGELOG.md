# Changelog

## 0.1.2

- Fix: inside a UIKit-hosted SwiftUI view the canvas could keep showing its first frame. Each timeline tick now draws a new frame.

## 0.1.1

- `OrbView` and `SpectrumOrbView` take a `tint` colour (default mint, as before).

## 0.1.0

First release.

- `WaveformCore`: exact columns (`ColumnBuilder`), windowed loudness with attack and release, a log-band spectrum (`SpectrumBuilder`), lock-free rings (`ColumnRing`, `SpectrumRing`), the audio-clock playhead (`StreamClock`, `Playhead`, `FrameClock`), Catmull-Rom windows, the orb's geometry (`OrbModel`), `LiveInput` for the microphone or a file, and synthetic test voices.
- `WaveformUI`: `WaveformView` (bars), `OrbView` (loudness orb) and `SpectrumOrbView` (pitch round the sphere, time down it).
