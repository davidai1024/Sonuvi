// Sonuvi — GPL-3.0. This document links to System Settings; it runs no code.
import AppKit

let file = CommandLine.arguments[1]
let source = NSWorkspace.shared.icon(forFile: "/System/Applications/System Settings.app")
let icon = NSImage(size: NSSize(width: 128, height: 128))
icon.lockFocus()
source.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
icon.unlockFocus()
guard NSWorkspace.shared.setIcon(icon, forFile: file, options: []) else {
    fputs("Cannot set privacy shortcut icon\n", stderr); exit(1)
}
var values = URLResourceValues(); values.hasHiddenExtension = true
var url = URL(fileURLWithPath: file); try url.setResourceValues(values)
if CommandLine.arguments.count > 2, let data = icon.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
