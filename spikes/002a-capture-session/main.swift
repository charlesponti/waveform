// Spike 002a — can AVFoundation's capture stack give us device-first PCM?
//
// Throwaway. Question: given a chosen AVCaptureDevice, does an AVCaptureSession with AVCaptureAudioDataOutput deliver
// 16 kHz mono 16-bit PCM from *that* device, with no AVAudioEngine graph to fight?
//
// Run: swift spikes/002a-capture-session/main.swift <uid-or-name-fragment> <seconds> <out.wav>

import AVFoundation
import CoreAudio
import Foundation

// MARK: - CoreAudio: the same lookup the app uses

func allDeviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func string(of device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func inputChannels(of device: AudioDeviceID) -> Int {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                             mScope: kAudioObjectPropertyScopeInput,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        .reduce(0) { $0 + Int($1.mNumberChannels) }
}

func defaultInputUID() -> String? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                     &size, &deviceID) == noErr, deviceID != 0 else { return nil }
    return string(of: deviceID, kAudioDevicePropertyDeviceUID)
}

func runningInputNames() -> [String] {
    allDeviceIDs().compactMap { id in
        guard inputChannels(of: id) > 0 else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &running) == noErr, running != 0 else { return nil }
        return string(of: id, kAudioObjectPropertyName)
    }
}

/// The delegate AVFoundation needs: it hands us sample buffers and nothing else.
final class SampleSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let onBuffer: (CMSampleBuffer) -> Void
    init(_ onBuffer: @escaping (CMSampleBuffer) -> Void) { self.onBuffer = onBuffer }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onBuffer(sampleBuffer)
    }
}

// MARK: - The spike

// Unbuffered: a trap otherwise takes every buffered line with it and leaves an empty log.
setbuf(stdout, nil)

let args = CommandLine.arguments
guard args.count >= 4 else {
    print("usage: main.swift <uid-fragment|name-fragment> <seconds> <out.wav>")
    exit(2)
}
let wanted = args[1].lowercased()
let seconds = Double(args[2]) ?? 3
let output = URL(fileURLWithPath: args[3])

print("devices with input streams:")
var chosen: AVCaptureDevice?
for device in AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                               mediaType: .audio,
                                               position: .unspecified).devices {
    let isDefault = device.uniqueID == AVCaptureDevice.default(for: .audio)?.uniqueID
    print("  \(isDefault ? "*" : " ") \(device.localizedName)   \(device.uniqueID)")
    // match on either the CoreAudio UID in the name, or the name itself
    if device.localizedName.lowercased().contains(wanted) || device.uniqueID.lowercased().contains(wanted) {
        if chosen == nil { chosen = device }
    }
}
guard let chosen else { print("no device matched \(wanted)"); exit(1) }
print("\nchosen: \(chosen.localizedName)  uid=\(chosen.uniqueID)")
print("system default: \(AVCaptureDevice.default(for: .audio)?.localizedName ?? "none")")

let session = AVCaptureSession()
session.beginConfiguration()
if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
do {
    let input = try AVCaptureDeviceInput(device: chosen)
    guard session.canAddInput(input) else { print("session refused the input device"); exit(1) }
    session.addInput(input)
} catch {
    print("could not open the device: \(error)")
    exit(1)
}

let out = AVCaptureAudioDataOutput()
// Ask AVFoundation for exactly what the transcription engine reads: 16 kHz mono 16-bit PCM, no conversion of our own.
out.audioSettings = [
    AVFormatIDKey: Int(kAudioFormatLinearPCM),
    AVSampleRateKey: 16_000.0,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsFloatKey: false,
    AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsNonInterleaved: false,
]
guard session.canAddOutput(out) else { print("session refused the data output"); exit(1) }
session.addOutput(out)
session.commitConfiguration()

try? FileManager.default.removeItem(at: output)
var file: AVAudioFile?
var frames: AVAudioFrameCount = 0
var writes = 0
var formatSeen = "none"

// AVCaptureOutput holds its delegate weakly: an inline sink is deallocated before the first buffer arrives.
let sink = SampleSink { sample in
    guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
    let length = CMBlockBufferGetDataLength(block)
    guard length > 0 else { return }
    if file == nil {
        let fmt = CMAudioFormatDescriptionGetStreamBasicDescription(
            CMSampleBufferGetFormatDescription(sample)!)?.pointee
        let isFloat = ((fmt?.mFormatFlags ?? 0) & kAudioFormatFlagIsFloat) != 0
        formatSeen = "\(fmt?.mSampleRate ?? 0) Hz, \(fmt?.mChannelsPerFrame ?? 0) ch, bits=\(fmt?.mBitsPerChannel ?? 0), float=\(isFloat)"
        file = try? AVAudioFile(forWriting: output, settings: [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        print("first buffer format: \(formatSeen)")
    }
    // AVAudioFile converts from a Float32 processing buffer to whatever the file holds (16-bit here). Handing it an
    // Int16 buffer asserts instead.
    guard let file,
          let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else { return }
    let framesInBuffer = AVAudioFrameCount(length / 2)   // 16-bit mono
    guard let pcm = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: framesInBuffer),
          let dst = pcm.floatChannelData?[0] else { return }
    pcm.frameLength = framesInBuffer
    // A block buffer is not always one contiguous run; a copy needs a destination big enough for the *total* length,
    // and the trap in the naive version was asking for `length/multiple-of-two` frames from a buffer whose length did
    // not divide evenly. Check contiguity, take the pointer, and copy exactly the bytes present.
    guard CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: 0) else {
        print("non-contiguous block (length=\(length)) — skipping")
        return
    }
    var lengthAtOffset = 0
    var totalLength = 0
    var pointer: UnsafeMutablePointer<Int8>?
    guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                      totalLengthOut: &totalLength, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
          let pointer else { print("no data pointer"); return }
    let sampleCount = totalLength / MemoryLayout<Int16>.size
    guard sampleCount <= Int(pcm.frameCapacity) else { print("buffer too large: \(totalLength)"); return }
    pcm.frameLength = AVAudioFrameCount(sampleCount)
    pointer.withMemoryRebound(to: Int16.self, capacity: sampleCount) { src in
        for i in 0..<sampleCount { dst[i] = Float(src[i]) / 32768.0 }
    }
    do {
        try file.write(from: pcm)
        frames += framesInBuffer
        writes += 1
        if writes <= 3 { print("buffer \(writes): \(framesInBuffer) frames (\(length) bytes)") }
    } catch {
        print("write failed: \(error)")
    }
}
out.setSampleBufferDelegate(sink, queue: DispatchQueue(label: "spike.capture"))

print("\nstarting session…")
session.startRunning()
print("running=\(runningInputNames().joined(separator: ", "))")
// A capture session delivers through the run loop; a bare sleep on the main thread receives nothing at all.
let deadline = Date().addingTimeInterval(seconds)
while Date() < deadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
session.stopRunning()
Thread.sleep(forTimeInterval: 0.4)
// Releasing the last reference to the AVAudioFile writes its footer. Until then the header holds zeros and afinfo
// reports a 0-second file — the same trap as reading a WAV that is still being written.
file = nil

print("\n--- result ---")
print("buffers written : \(writes)")
print("frames          : \(frames)  (\(Double(frames) / 16_000) s)")
print("buffer format   : \(formatSeen)")
print("running at start: \(runningInputNames().joined(separator: ", "))")
print("file            : \(output.path)")
