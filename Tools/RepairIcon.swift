// Sonuvi — GPL-3.0. Finder custom icon for the first-open helper.
import AppKit

let size = NSSize(width: 128, height: 128)
let icon = NSImage(size: size)
icon.lockFocus()
NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 9, y: 9, width: 110, height: 110), xRadius: 25, yRadius: 25).fill()
NSColor(calibratedWhite: 0.82, alpha: 1).setStroke()
let border = NSBezierPath(roundedRect: NSRect(x: 9.5, y: 9.5, width: 109, height: 109), xRadius: 25, yRadius: 25)
border.lineWidth = 1; border.stroke()
let configuration = NSImage.SymbolConfiguration(pointSize: 54, weight: .medium)
    .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(calibratedWhite: 0.28, alpha: 1)]))
if let symbol = NSImage(systemSymbolName: "wrench.and.screwdriver.fill", accessibilityDescription: "首次打开修复")?.withSymbolConfiguration(configuration) {
    symbol.draw(in: NSRect(x: 34, y: 34, width: 60, height: 60))
}
icon.unlockFocus()
let file = CommandLine.arguments[1]
guard NSWorkspace.shared.setIcon(icon, forFile: file, options: []) else {
    fputs("Cannot set helper Finder icon\n", stderr); exit(1)
}
var values = URLResourceValues(); values.hasHiddenExtension = true
var url = URL(fileURLWithPath: file); try url.setResourceValues(values)
if CommandLine.arguments.count > 2, let data = icon.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
