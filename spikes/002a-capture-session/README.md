# 002a — device-first capture with AVFoundation

**Question.** Given a chosen `AVCaptureDevice`, does an `AVCaptureSession` with `AVCaptureAudioDataOutput` deliver
16 kHz mono 16-bit PCM from *that* device, with no `AVAudioEngine` graph to fight?

**Why it matters.** #19 in Ponte: `kAudioOutputUnitProperty_CurrentDevice` on an `AVAudioEngine`'s input node is
accepted and the hardware really switches, but the engine's cached graph keeps the old format and AVFAudio aborts on
the tap. The capture path has to become device-first, and this decides whether AVFoundation's capture stack can do it.

**How.** `swiftc -O main.swift -o /tmp/spike002a`, then `/tmp/spike002a wave 3 /tmp/spike002a.wav` — choosing a device
by name fragment while the *system default* was a different microphone (built-in), so a pass cannot be luck.

## Verdict: VALIDATED

```
chosen: Wave Link MicrophoneFX  uid=ElgatoWaveLinkMicrophoneFXIn
system default: MacBook Pro Microphone
running=MacBook Pro Microphone, Wave Link MicrophoneFX     ← the chosen device really opened
buffer format: 16000.0 Hz, 1 ch, bits=16, float=false      ← exactly what the engine reads
buffers written: 567   frames: 48378  (3.023625 s)
afinfo: 1 ch, 16000 Hz, Int16 · 3.023625 sec · 96,756 audio bytes
```

A non-default device, the exact target format, a valid WAV, and a duration within 24 ms of what was asked for.

### What worked

- `AVCaptureDeviceInput(device:)` takes a device directly. There is no graph, so nothing to repoint and no format to
  disagree with.
- `AVCaptureAudioDataOutput.audioSettings` converts for you: asking for linear PCM at 16 kHz mono 16-bit yields
  exactly that in every sample buffer. No `AVAudioConverter`, no resampling of our own.
- Everything downstream is unchanged: buffers in, `AVAudioFile` out.

### What didn't — five traps, all found the hard way

1. **`startRunning` between `beginConfiguration` and `commitConfiguration` throws** an `NSGenericException`. Commit
   before starting.
2. **A bare `Thread.sleep` receives nothing.** A capture session delivers through the run loop; a command-line tool
   must pump it (`RunLoop.current.run(mode:before:)`) or the delegate is never called.
3. **`AVCaptureOutput` holds its delegate weakly.** An inline `setSampleBufferDelegate(SampleSink { … })` is
   deallocated before the first buffer. Hold it in a variable.
4. **`AVAudioFile.write(from:)` asserts on an Int16 buffer.** Its processing format is Float32; hand it a standard
   Float32 buffer and let it convert to the 16-bit file.
5. **A `CMSampleBuffer`'s block is not necessarily one contiguous run**, and its length does not always divide evenly
   by the sample size. Check `CMBlockBufferIsRangeContiguous`, take `CMBlockBufferGetDataPointer`, and copy exactly
   the bytes present.

Bonus, from the same family as the live-transcript work: **the file's header is only written when the last
`AVAudioFile` reference is released.** Until then `afinfo` reports a 0-second file with 0 audio bytes, which reads
exactly like a capture that recorded nothing.

### Surprises

- Buffer sizes are tiny — 85–86 frames — so a consumer must not assume a buffer is a sizeable chunk. 567 buffers for
  3 seconds is about 190 a second.
- The chosen device stays open while the *default* is also open (`running=` shows both), which is worth knowing for
  the "who is holding the microphone" question.
- A virtual device (Wave Link) captures perfectly but is silent on this machine (−91 dB), so a level check is not a
  validity check: 3.02 s of near-silence is a correct capture of a muted input.

## Recommendation for the real build

Introduce an `AudioSource` seam in `WaveformCapture`, because the engine and the capture session differ only in how
buffers arrive:

```swift
protocol AudioSource {                       // in WaveformCapture
    func start(onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) throws
    func stop()
}
```

- `EngineSource` — today's `AVAudioEngine` + tap, unchanged, so Thames keeps working exactly as it does now.
- `CaptureSource` — `AVCaptureSession` + `AVCaptureAudioDataOutput` + the device UID, using the recipe above.
- `EngineRecorder` keeps its converter, column builder, writer, ballistics and route handling; only the two `installTap`
  sites move behind the seam.

`CaptureSettings` grows `deviceUID: String?` (nil = system default), which is additive and changes no existing call site.

This is throwaway code: it exists to answer the question, not to be lifted. The recipe in "five traps" is the part
worth keeping.
