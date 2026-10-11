import AVFoundation

/// Asks the system for the microphone. This is the one line of the package that only a person at a
/// device can run (it raises the system's permission dialog), so it lives alone in this file, which
/// `scripts/coverage.sh` leaves out of the measurement. Everything around it takes the answer as a
/// closure and is tested with both answers.
@Sendable public func systemMicrophoneAccess() async -> Bool {
  await AVCaptureDevice.requestAccess(for: .audio)
}
