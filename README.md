# Waveform

A voice waveform tried outside Thames. `WaveformCore` makes the columns (exact, no allocation, no lock);
`WaveformApp` draws them.

```sh
swift test                                              # accuracy tests
swift run -c release WaveformApp                        # the microphone
swift run -c release WaveformApp --file voice.m4a       # play a file and draw it
swift run -c release WaveformApp --snapshot out.png     # a picture of a made-up voice
swift run -c release WaveformApp --bench                # speed of the column maker
```

- `ColumnBuilder`: samples in, columns out (lowest, highest, loudness) at a steady rate. Edges sit on whole
  samples counted from the start, so any buffer size gives the same columns.
- `ColumnRing`: the audio thread writes, the screen reads, with no lock; a read that was overtaken is redone.
- `Scale`: linear, or decibels so quiet speech is visible next to loud.
- `OrbModel`: the dots on a sphere (even spacing), and the maths from columns to shape: height up the sphere = age of the sound (equator newest, poles oldest), push-out = loudness, dot size = peak.
- `WaveformView`: two filled paths per frame; the row slides between column arrivals so 120 Hz screens look smooth.

`swift run -c release WaveformApp --orb-snapshot out.png` writes four moments of the made-up voice as an orb.
