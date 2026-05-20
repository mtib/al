import Foundation
import SwiftUI

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

    /// Stable per-install UUID. Generated lazily and never changes after that.
    let clientId: String

    private init() {
        let d = UserDefaults.standard
        self.serverURL = d.string(forKey: Key.serverURL) ?? ""
        self.psk = d.string(forKey: Key.psk) ?? ""
        // Default to true if the key has never been written.
        self.writeLocally = d.object(forKey: Key.writeLocally) as? Bool ?? true
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
