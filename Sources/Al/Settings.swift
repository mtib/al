import Foundation
import SwiftUI

/// Cases are declared in **descending strength order** (best transcription
/// quality first). `OptionsView` walks `allCases` so the picker shows the
/// most accurate model at the top.
enum ASRModel: String, CaseIterable {
    case parakeet06b               = "parakeet"        // raw value kept for migration
    case parakeet110m              = "parakeet110m"
    case fastConformerMultilingual = "fastConformerMultilingual"
    case moonshineTiny             = "moonshine"

    var displayName: String {
        switch self {
        case .parakeet110m:
            return "Parakeet TDT-CTC 110M — English, best quality (~99 MB)"
        case .fastConformerMultilingual:
            return "FastConformer CTC — EN/DE/ES/FR multilingual (~98 MB)"
        case .parakeet06b:
            return "Parakeet TDT 0.6B v3 — English, heavy beast (~465 MB)"
        case .moonshineTiny:
            return "Moonshine Tiny — English, smallest footprint (~45 MB)"
        }
    }

    /// Two-letter ISO language tags this model can transcribe. Used for UI labelling.
    var languages: [String] {
        switch self {
        case .parakeet110m, .parakeet06b, .moonshineTiny: return ["en"]
        case .fastConformerMultilingual:                  return ["en", "de", "es", "fr"]
        }
    }
}

/// Observable user-configurable settings. Backed by UserDefaults.
///
/// The pre-shared key (PSK) is stored in UserDefaults in plain text — this is
/// a single-user, local-only macOS app; we deliberately avoid Keychain to
/// keep the dependency surface small. If you share this machine, treat the
/// PSK as you would any other long-lived API token.
@MainActor
final class Settings: ObservableObject {

    static let shared = Settings()

    private enum Key {
        static let serverURL    = "al.server.url"
        static let psk          = "al.server.psk"
        static let clientId     = "al.client.id"
        static let writeLocally = "al.transcript.writeLocally"
        static let asrModel     = "al.asr.model"
    }

    @Published var serverURL: String {
        didSet {
            UserDefaults.standard.set(serverURL, forKey: Key.serverURL)
            NotificationCenter.default.post(name: Settings.didChange, object: self)
        }
    }

    @Published var psk: String {
        didSet {
            UserDefaults.standard.set(psk, forKey: Key.psk)
            NotificationCenter.default.post(name: Settings.didChange, object: self)
        }
    }

    /// When false, the `TranscriptWriter` does not create or write any files
    /// under `~/Documents/al/`. The shipper still runs (if configured) and
    /// the menu-bar popover keeps showing recent lines from its in-memory
    /// ring buffer.
    @Published var writeLocally: Bool {
        didSet {
            UserDefaults.standard.set(writeLocally, forKey: Key.writeLocally)
            NotificationCenter.default.post(name: Settings.didChange, object: self)
        }
    }

    /// Pipeline restarts when this changes (see MenuBarController).
    @Published var asrModel: ASRModel {
        didSet {
            UserDefaults.standard.set(asrModel.rawValue, forKey: Key.asrModel)
            NotificationCenter.default.post(name: Settings.didChange, object: self)
        }
    }

    /// Stable per-install UUID. Generated lazily and never changes after that.
    let clientId: String

    private init() {
        let d = UserDefaults.standard
        self.serverURL = d.string(forKey: Key.serverURL) ?? ""
        self.psk = d.string(forKey: Key.psk) ?? ""
        self.writeLocally = d.object(forKey: Key.writeLocally) as? Bool ?? true
        self.asrModel = ASRModel(rawValue: d.string(forKey: Key.asrModel) ?? "") ?? .parakeet110m
        if let existing = d.string(forKey: Key.clientId), !existing.isEmpty {
            self.clientId = existing
        } else {
            let id = UUID().uuidString
            d.set(id, forKey: Key.clientId)
            self.clientId = id
        }
    }

    /// True when both a server URL and PSK are present and the URL parses.
    var isShippingConfigured: Bool {
        guard !psk.isEmpty, let url = URL(string: serverURL.trimmingCharacters(in: .whitespaces)) else {
            return false
        }
        return url.scheme == "http" || url.scheme == "https"
    }

    var resolvedServerURL: URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    static let didChange = Notification.Name("al.settings.didChange")
}
