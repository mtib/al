import AppKit
import SwiftUI

/// Standalone preferences window. Lives behind a singleton controller so
/// repeated "Options…" clicks just bring the existing window forward.
@MainActor
final class OptionsWindowController {

    static let shared = OptionsWindowController()

    private var window: NSWindow?

    func show() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let view = OptionsView()
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = "Al — Options"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 480, height: 440))
        w.center()
        self.window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}


/// State for the Options window. Edits live in this object until the user
/// hits Save, which writes them through to `Settings.shared`.
@MainActor
final class OptionsViewModel: ObservableObject {

    @Published var serverURL: String
    @Published var psk: String
    @Published var writeLocally: Bool
    @Published var asrModel: ASRModel
    @Published var testing: Bool = false
    @Published var testResult: TestResult = .idle
    let clientId: String

    enum TestResult: Equatable {
        case idle
        case ok(validUntil: Double?)
        case failed(String)

        var label: String {
            switch self {
            case .idle: return ""
            case .ok(let validUntil):
                guard let until = validUntil, until > 0 else { return "Reachable — pubkey fetched." }
                let secs = until - Date().timeIntervalSince1970
                if secs < 0 { return "Reachable — but pubkey is already expired (will rotate on next call)." }
                if secs < 3600 { return String(format: "Reachable — pubkey valid for %.0f min.", secs / 60) }
                return String(format: "Reachable — pubkey valid for %.1f h.", secs / 3600)
            case .failed(let msg): return "Failed: \(msg)"
            }
        }

        var isOK: Bool {
            if case .ok = self { return true }
            return false
        }
    }

    init() {
        let s = Settings.shared
        self.serverURL = s.serverURL
        self.psk = s.psk
        self.writeLocally = s.writeLocally
        self.asrModel = s.asrModel
        self.clientId = s.clientId
    }

    func save() {
        let s = Settings.shared
        s.serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        s.psk = psk
        s.writeLocally = writeLocally
        s.asrModel = asrModel
    }

    func clearShipping() {
        serverURL = ""
        psk = ""
        save()
        testResult = .idle
    }

    func testConnection() async {
        testing = true
        defer { testing = false }

        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" else {
            testResult = .failed("Invalid URL — must start with http:// or https://")
            return
        }
        guard !psk.isEmpty else {
            testResult = .failed("Pre-shared key is empty")
            return
        }

        var req = URLRequest(url: url.appendingPathComponent("pubkey"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(psk)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                testResult = .failed("Non-HTTP response")
                return
            }
            guard http.statusCode == 200 else {
                if http.statusCode == 401 {
                    testResult = .failed("401 Unauthorized — wrong pre-shared key")
                } else {
                    testResult = .failed("HTTP \(http.statusCode)")
                }
                return
            }
            struct Pub: Codable { let public_key_b64: String; let valid_until: Double? }
            let body = try JSONDecoder().decode(Pub.self, from: data)
            guard let bytes = Data(base64Encoded: body.public_key_b64), bytes.count == 32 else {
                testResult = .failed("Server returned malformed key")
                return
            }
            testResult = .ok(validUntil: body.valid_until)
        } catch {
            testResult = .failed(error.localizedDescription)
        }
    }
}


/// Options form. Edits stay local until Save, so users can experiment with
/// the test button without churning the shipper.
struct OptionsView: View {
    @StateObject private var model = OptionsViewModel()

    var body: some View {
        Form {
            Section {
                Text("Local transcripts")
                    .font(.headline)
                Toggle("Write transcripts to ~/Documents/al/", isOn: $model.writeLocally)
                Text(model.writeLocally
                     ? "Each utterance is appended to a date-bucketed file on disk."
                     : "Disk writes are disabled. Recent lines are still kept in memory and shown in the popover; if a server is configured they're also shipped.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 10)

            Section {
                Text("Transcription model")
                    .font(.headline)
                Picker("ASR model", selection: $model.asrModel) {
                    ForEach(ASRModel.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Takes effect immediately — the pipeline restarts automatically when you save.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 10)

            Section {
                Text("Log shipping (optional)")
                    .font(.headline)
                Text("When a server URL and pre-shared key are set, every transcribed utterance is encrypted to the server's X25519 public key and pushed in batches. Every request — including the public-key fetch — sends the PSK as `Authorization: Bearer …`.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 6)

            Section {
                LabeledContent("Server URL") {
                    TextField("https://al.example.com", text: $model.serverURL)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }
                LabeledContent("Pre-shared key") {
                    SecureField("paste your PSK", text: $model.psk)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Client ID") {
                    Text(model.clientId)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if !model.testResult.label.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: model.testResult.isOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.testResult.isOK ? .green : .orange)
                    Text(model.testResult.label)
                        .font(.callout)
                }
                .padding(.top, 4)
            }

            HStack {
                Button("Test connection") {
                    Task { await model.testConnection() }
                }
                .disabled(model.testing || model.serverURL.isEmpty || model.psk.isEmpty)

                if model.testing {
                    ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                }

                Spacer()

                Button("Disable shipping") {
                    model.clearShipping()
                }
                .disabled(model.serverURL.isEmpty && model.psk.isEmpty)

                Button("Save") {
                    model.save()
                }
                .keyboardShortcut(.return)
            }
            .padding(.top, 10)
        }
        .padding(16)
        .frame(width: 480)
    }
}
