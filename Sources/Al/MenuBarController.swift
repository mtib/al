import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {

    private let statusItem: NSStatusItem
    private let pipeline: Pipeline
    private let popover = NSPopover()
    private let model = MenuBarViewModel()

    init(pipeline: Pipeline) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.pipeline = pipeline
        super.init()
        configureButton()
        configurePopover()
        wireCallbacks()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let img = NSImage(systemSymbolName: "ear.fill", accessibilityDescription: "Al")
                  ?? NSImage(systemSymbolName: "ear", accessibilityDescription: "Al")
        img?.isTemplate = true
        button.image = img
        button.toolTip = "Al — Always Listen"
        button.target = self
        button.action = #selector(togglePopover)
    }

    private func configurePopover() {
        let view = MenuBarContentView(
            model: model,
            onToggleListening: { [weak self] in self?.toggleListening() },
            onOpenCurrentLog:  { [weak self] in self?.openCurrentLog() },
            onOpenLogFolder:   { [weak self] in self?.openLogFolder() },
            onOpenMicSettings: { [weak self] in self?.openMicSettings() },
            onOpenScreenSettings: { [weak self] in self?.openScreenSettings() },
            onOpenOptions:     { [weak self] in self?.openOptions() },
            onOpenBrowser:     { [weak self] in self?.openBrowser() },
            onQuit:            { [weak self] in self?.quit() }
        )
        popover.contentViewController = NSHostingController(rootView: view)
        popover.behavior = .transient
        popover.delegate = self
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshPermissionCache()
            self.model.currentLogURL = await self.pipeline.currentFile()
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Make the popover key so keyboard shortcuts (Return, Cmd-Q) reach it.
            self.popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func wireCallbacks() {
        pipeline.onStatus = { [weak self] label in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cap = label.prefix(1).uppercased() + label.dropFirst()
                self.model.statusLabel = String(cap)
                self.model.isRunning = label.hasPrefix("running")
            }
        }
        pipeline.onUtterance = { [weak self] utt in
            Task { @MainActor [weak self] in
                self?.model.append(utt)
            }
        }
        NotificationCenter.default.addObserver(
            forName: Settings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.pipeline.state == .running else { return }
                await self.pipeline.stop()
                await self.pipeline.start()
            }
        }
    }

    // MARK: - Actions

    private func toggleListening() {
        Task { @MainActor in
            switch self.pipeline.state {
            case .running:  await self.pipeline.stop()
            case .stopped:  await self.pipeline.start()
            case .starting, .stopping: break
            }
        }
    }

    private func openCurrentLog() {
        Task {
            if let url = await pipeline.currentFile() {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func openLogFolder() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
            .appendingPathComponent("al")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    private func openMicSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    private func openScreenSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    private func openOptions() {
        popover.performClose(nil)
        OptionsWindowController.shared.show()
    }

    private func openBrowser() {
        popover.performClose(nil)
        BrowserWindowController.shared.show()
    }

    private func quit() { NSApplication.shared.terminate(nil) }

    /// Called from `applicationShouldTerminate` so the UI reflects that
    /// shutdown is in progress while the pipeline drains on a detached task.
    /// We close the popover (it can't be useful any more), dim the status
    /// item icon, and overwrite the status label so any subsequent
    /// "stopped" / "stopping" callbacks from the pipeline don't fight us.
    func beginQuitTransition() {
        popover.performClose(nil)
        if let button = statusItem.button {
            button.appearsDisabled = true
            button.toolTip = "Al — quitting…"
        }
        model.statusLabel = "Quitting…"
        model.isRunning = false
        // Suppress further pipeline status updates so the label doesn't
        // flicker to "Stopping" / "Stopped" before the process actually exits.
        pipeline.onStatus = nil
        pipeline.onUtterance = nil
    }

    // MARK: - Permissions

    /// Request both permissions (shows system prompts if not yet determined),
    /// then update the cache. Called once on launch.
    func requestAndRefresh() async {
        model.micStatus = await Permissions.requestMicrophone()
        model.sysStatus = await Permissions.requestScreenRecording()
    }

    /// Probe current status without prompting; update cache.
    private func refreshPermissionCache() async {
        model.micStatus = Permissions.microphoneStatus()
        model.sysStatus = await Permissions.screenRecordingStatus()
    }
}
