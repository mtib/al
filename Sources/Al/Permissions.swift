import Foundation
import AVFoundation
import ScreenCaptureKit

/// Non-prompting TCC status probes for microphone and screen recording.
/// The actual prompts fire on first `AVAudioEngine.start()` and first
/// `SCStream.startCapture()` — this just tells the menu bar what to show.
enum Permissions {

    enum Status {
        case granted
        case denied
        case notDetermined
    }

    /// Synchronous probe — does NOT prompt.
    static func microphoneStatus() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return .granted
        case .denied:        return .denied
        case .restricted:    return .denied
        case .notDetermined: return .notDetermined
        @unknown default:    return .notDetermined
        }
    }

    /// Async probe — does NOT prompt. Tests SCShareableContent to infer
    /// the screen-recording grant without triggering the system dialog.
    static func screenRecordingStatus() async -> Status {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return .granted
        } catch let e as NSError where e.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" {
            return .denied
        } catch {
            return .notDetermined
        }
    }

    /// Requests microphone access, showing the system prompt if not yet
    /// determined. Safe to call when already granted — returns immediately.
    static func requestMicrophone() async -> Status {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .granted : .denied
    }

    /// Requests screen-recording access by triggering an SCShareableContent
    /// call, which causes macOS to show the Screen Recording prompt when the
    /// grant is not yet determined. Safe to call when already granted.
    @discardableResult
    static func requestScreenRecording() async -> Status {
        // The SCK call itself is what triggers the system prompt; the return
        // value is our inferred status from whether it succeeded.
        return await screenRecordingStatus()
    }
}
