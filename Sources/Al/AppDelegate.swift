import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    let pipeline = Pipeline()
    var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.line("Al: launched")
        menuBar = MenuBarController(pipeline: pipeline)
        // Request mic + screen-recording permissions immediately on launch
        // so the user sees the system prompts right away and the menu bar
        // shows accurate grant status from the first open.
        Task { @MainActor in
            await self.menuBar.requestAndRefresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.line("Al: terminating — draining pipeline")
        // Block briefly for a clean shutdown (writer flush + engine unload).
        let group = DispatchGroup()
        group.enter()
        Task {
            await pipeline.stop()
            group.leave()
        }
        _ = group.wait(timeout: .now() + 5)
        Log.line("Al: bye")
    }
}
