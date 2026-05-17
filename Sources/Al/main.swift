import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .accessory matches LSUIElement=true — no Dock icon, no menu bar takeover.
app.setActivationPolicy(.accessory)
app.run()
