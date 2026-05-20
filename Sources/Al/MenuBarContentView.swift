import SwiftUI
import AppKit

/// Observable state backing the menu-bar popover. Mutated only on @MainActor;
/// the popover SwiftUI view re-renders automatically as values change.
@MainActor
final class MenuBarViewModel: ObservableObject {
    struct Line: Identifiable, Equatable {
        let id = UUID()
        let timeLabel: String
        let source: SourceTag
        let text: String
    }

    @Published var statusLabel: String = "Idle"
    @Published var isRunning: Bool = false
    @Published var micStatus: Permissions.Status = .notDetermined
    @Published var sysStatus: Permissions.Status = .notDetermined
    @Published var currentLogURL: URL?
    @Published private(set) var lines: [Line] = []

    /// Cap on retained lines — older entries scroll out of the in-memory ring.
    /// The on-disk transcript is the source of truth; this is just for UI.
    private let maxLines = 200

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func append(_ utt: Utterance) {
        lines.append(Line(
            timeLabel: timeFormatter.string(from: utt.endedAt),
            source: utt.source,
            text: utt.text
        ))
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }
}

/// Popover content. Vertically: status row, primary action, secondary actions,
/// permission chips, live transcript list, quit.
struct MenuBarContentView: View {
    @ObservedObject var model: MenuBarViewModel
    @ObservedObject var settings: Settings = .shared
    let onToggleListening: () -> Void
    let onOpenCurrentLog: () -> Void
    let onOpenLogFolder: () -> Void
    let onOpenMicSettings: () -> Void
    let onOpenScreenSettings: () -> Void
    let onOpenOptions: () -> Void
    let onOpenBrowser: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow
            actionRow
            permissionRow
            Divider()
            transcriptList
            Divider()
            HStack {
                Button("Options…", action: onOpenOptions)
                    .keyboardShortcut(",")
                Button("Browse…", action: onOpenBrowser)
                    .keyboardShortcut("b")
                Spacer()
                Button("Quit Al", action: onQuit)
                    .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 380)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isRunning ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(model.statusLabel)
                .font(.headline)
            Spacer()
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button(model.isRunning ? "Stop Listening" : "Start Listening",
                   action: onToggleListening)
                .keyboardShortcut(.return)
            if settings.writeLocally {
                Button("Open Current Log", action: onOpenCurrentLog)
                    .disabled(model.currentLogURL == nil)
                Button("Open Folder", action: onOpenLogFolder)
            }
            Spacer()
        }
    }

    private var permissionRow: some View {
        HStack(spacing: 12) {
            permissionChip(
                icon: "mic.fill",
                label: "Microphone",
                status: model.micStatus,
                action: onOpenMicSettings
            )
            permissionChip(
                icon: "rectangle.dashed.badge.record",
                label: "Screen",
                status: model.sysStatus,
                action: onOpenScreenSettings
            )
            Spacer()
        }
    }

    private func permissionChip(
        icon: String,
        label: String,
        status: Permissions.Status,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(label)
                statusIcon(for: status)
            }
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .help("Click to open System Settings")
    }

    @ViewBuilder
    private func statusIcon(for s: Permissions.Status) -> some View {
        switch s {
        case .granted:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .notDetermined:
            Image(systemName: "questionmark.circle.fill").foregroundStyle(.secondary)
        }
    }

    private var transcriptList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent transcripts")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if model.lines.isEmpty {
                            Text("Nothing yet — speak and Al will append lines here.")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(model.lines) { line in
                                lineRow(line).id(line.id)
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                )
                .onChange(of: model.lines.count) { _, _ in
                    if let last = model.lines.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func lineRow(_ line: MenuBarViewModel.Line) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(line.timeLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            Image(systemName: line.source == .mic ? "mic.fill" : "speaker.wave.2.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(line.text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
