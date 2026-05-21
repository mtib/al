import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    let pipeline = Pipeline()
    var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.line("Al: launched")
        // Accessory apps don't get a main menu by default, which means ⌘C / ⌘V / ⌘A
        // / ⌘Z never reach the focused text field. Install a minimal one so the
        // Options and Browse windows behave like normal Mac apps.
        NSApp.mainMenu = Self.buildMainMenu()
        menuBar = MenuBarController(pipeline: pipeline)
        // Request mic + screen-recording permissions immediately on launch
        // so the user sees the system prompts right away and the menu bar
        // shows accurate grant status from the first open.
        Task { @MainActor in
            await self.menuBar.requestAndRefresh()
            await LogShipper.shared.start()
            await self.pipeline.start()
        }
    }

    /// Build a tiny App + Edit + Window menu so standard keyboard shortcuts
    /// work in our SwiftUI windows. We deliberately don't expose the menu in
    /// the system menu bar — `.accessory` activation policy keeps it hidden;
    /// the menu items exist solely to make the responder chain wire up the
    /// Cocoa text actions to ⌘ keys.
    private static func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        // App menu (Quit). Title for the first submenu is auto-overridden by
        // AppKit with the process name; we still need at least one item here.
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Al",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Al",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        // Edit menu — the actual reason this exists.
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo",
                         action: Selector(("undo:")),
                         keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo",
                                    action: Selector(("redo:")),
                                    keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)),
                         keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)),
                         keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)),
                         keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete",
                         action: #selector(NSText.delete(_:)),
                         keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")
        editItem.submenu = editMenu

        // Window menu so ⌘W closes the focused window.
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowItem.submenu = windowMenu
        return main
    }

    /// Polished quit: hand AppKit a `.terminateLater` reply, drain on a
    /// background task, then unblock termination once writers are flushed.
    /// Keeps the run loop pumping so the popover closes and the menu-bar
    /// icon stays responsive instead of looking frozen for a few seconds.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Log.line("Al: terminating — draining pipeline (deferred)")
        menuBar?.beginQuitTransition()
        Task.detached(priority: .userInitiated) { [pipeline] in
            await pipeline.stop()
            await LogShipper.shared.stop()
            await MainActor.run {
                Log.line("Al: bye")
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}
