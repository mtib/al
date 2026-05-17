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

    /// Synchronous — reads AVCaptureDevice authorization status without prompting.
    static func microphoneStatus() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return .granted
        case .denied:        return .denied
        case .restricted:    return .denied
        case .notDetermined: return .notDetermined
        @unknown default:    return .notDetermined
        }
    }

    /// Async — tests SCShareableContent to infer screen-recording grant.
    /// Returns `.granted` if the call succeeds, `.denied` on SCK permission
    /// errors, `.notDetermined` otherwise.
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
}
