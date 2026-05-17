import AppKit

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <out_dir>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])
let iconset = outDir.appendingPathComponent("icon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "16x16"), (32, "16x16@2x"),
    (32, "32x32"), (64, "32x32@2x"),
    (128, "128x128"), (256, "128x128@2x"),
    (256, "256x256"), (512, "256x256@2x"),
    (512, "512x512"), (1024, "512x512@2x"),
]

// Try "ear.fill" first; fall back to "ear" on older macOS
let symbolName = NSImage(systemSymbolName: "ear.fill", accessibilityDescription: nil) != nil
    ? "ear.fill" : "ear"

for (px, label) in sizes {
    let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.72, weight: .regular)
    guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil),
          let img = base.withSymbolConfiguration(cfg) else { continue }

    let canvas = NSImage(size: NSSize(width: px, height: px))
    canvas.lockFocus()
    // Fill background transparent; the symbol renders in template black
    // (iconutil tints it correctly for different macOS appearances).
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    canvas.unlockFocus()

    guard let tiff = canvas.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    let dst = iconset.appendingPathComponent("icon_\(label).png")
    try? png.write(to: dst)
}

let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", iconset.path,
                  "-o", outDir.appendingPathComponent("icon.icns").path]
try? task.run()
task.waitUntilExit()
