import AppKit

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let pipeline: Pipeline

    private let statusRow    = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    private let startStopItem = NSMenuItem(title: "Start Listening", action: nil, keyEquivalent: "")
    private let openCurrentLogItem = NSMenuItem(title: "Open Current Log", action: nil, keyEquivalent: "")
    private let micPermItem  = NSMenuItem(title: "Microphone: checking…", action: nil, keyEquivalent: "")
    private let sysPermItem  = NSMenuItem(title: "System Audio: checking…", action: nil, keyEquivalent: "")

    init(pipeline: Pipeline) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.pipeline = pipeline
        super.init()
        configureButton()
        buildMenu()
        wireCallbacks()
        Task { await self.refreshPermissions() }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let img = NSImage(systemSymbolName: "ear.fill", accessibilityDescription: "Al")
                  ?? NSImage(systemSymbolName: "ear", accessibilityDescription: "Al")
        img?.isTemplate = true
        button.image = img
        button.toolTip = "Al — Always Listen"
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        statusRow.isEnabled = false
        menu.addItem(statusRow)
        menu.addItem(.separator())

        startStopItem.target = self
        startStopItem.action = #selector(toggleListening)
        menu.addItem(startStopItem)

        openCurrentLogItem.target = self
        openCurrentLogItem.action = #selector(openCurrentLog)
        openCurrentLogItem.isEnabled = false
        menu.addItem(openCurrentLogItem)

        let openFolderItem = NSMenuItem(title: "Open Log Folder", action: #selector(openLogFolder), keyEquivalent: "")
        openFolderItem.target = self
        menu.addItem(openFolderItem)

        menu.addItem(.separator())

        micPermItem.target = self
        micPermItem.action = #selector(openMicSettings)
        menu.addItem(micPermItem)

        sysPermItem.target = self
        sysPermItem.action = #selector(openScreenSettings)
        menu.addItem(sysPermItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Al", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func wireCallbacks() {
        pipeline.onStatus = { [weak self] label in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cap = label.prefix(1).uppercased() + label.dropFirst()
                self.statusRow.title = String(cap)
                self.startStopItem.title = label.hasPrefix("running") ? "Stop Listening" : "Start Listening"
            }
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshPermissions()
            let url = await self.pipeline.currentFile()
            if let url {
                self.openCurrentLogItem.title = "Open Current Log (\(url.lastPathComponent))"
                self.openCurrentLogItem.isEnabled = true
            } else {
                self.openCurrentLogItem.title = "Open Current Log (none yet)"
                self.openCurrentLogItem.isEnabled = false
            }
        }
    }

    // MARK: - Actions

    @objc private func toggleListening() {
        Task { @MainActor in
            switch self.pipeline.state {
            case .running:  await self.pipeline.stop()
            case .stopped:  await self.pipeline.start()
            case .starting, .stopping: break
            }
        }
    }

    @objc private func openCurrentLog() {
        Task {
            if let url = await pipeline.currentFile() {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func openLogFolder() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".al")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func openMicSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func openScreenSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    // MARK: - Permissions refresh

    private func refreshPermissions() async {
        let mic = Permissions.microphoneStatus()
        micPermItem.title = "Microphone: \(statusLabel(mic))"
        let sys = await Permissions.screenRecordingStatus()
        sysPermItem.title = "System Audio: \(statusLabel(sys))"
    }

    private func statusLabel(_ s: Permissions.Status) -> String {
        switch s {
        case .granted:       return "✓ granted"
        case .denied:        return "✗ denied — click to open Settings"
        case .notDetermined: return "not asked yet"
        }
    }
}
