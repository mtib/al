import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    let pipeline = Pipeline()
    var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.line("Al: launched")
        menuBar = MenuBarController(pipeline: pipeline)
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
