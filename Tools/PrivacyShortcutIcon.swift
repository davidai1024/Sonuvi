// Sonuvi — GPL-3.0. This document links to System Settings; it runs no code.
import AppKit

let file = CommandLine.arguments[1]
let icon = NSImage(size: NSSize(width: 128, height: 128))
icon.lockFocus()
let config = NSImage.SymbolConfiguration(pointSize: 42, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(calibratedWhite: 0.48, alpha: 1)]))
NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "打开隐私与安全性")?
    .withSymbolConfiguration(config)?.draw(in: NSRect(x: 42, y: 18, width: 44, height: 44))
icon.unlockFocus()
guard NSWorkspace.shared.setIcon(icon, forFile: file, options: []) else {
    fputs("Cannot set privacy shortcut icon\n", stderr); exit(1)
}
var values = URLResourceValues(); values.hasHiddenExtension = true
var url = URL(fileURLWithPath: file); try url.setResourceValues(values)
if CommandLine.arguments.count > 2, let data = icon.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
