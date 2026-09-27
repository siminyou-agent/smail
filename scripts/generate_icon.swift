import AppKit
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
NSColor(calibratedRed: 0.15, green: 0.38, blue: 0.30, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
NSColor(calibratedRed: 0.96, green: 0.95, blue: 0.88, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 205, y: 285, width: 614, height: 455), xRadius: 65, yRadius: 65).fill()
let flap = NSBezierPath(); flap.move(to: NSPoint(x: 230, y: 695)); flap.line(to: NSPoint(x: 512, y: 480)); flap.line(to: NSPoint(x: 794, y: 695))
NSColor(calibratedRed: 0.15, green: 0.38, blue: 0.30, alpha: 1).setStroke(); flap.lineWidth = 26; flap.lineJoinStyle = .round; flap.stroke()
NSColor(calibratedRed: 0.96, green: 0.69, blue: 0.29, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 670, y: 205, width: 210, height: 210)).fill()
let check = NSBezierPath(); check.move(to: NSPoint(x: 722, y: 313)); check.line(to: NSPoint(x: 762, y: 273)); check.line(to: NSPoint(x: 829, y: 351)); check.lineWidth = 23; check.lineCapStyle = .round; check.lineJoinStyle = .round
NSColor(calibratedRed: 0.15, green: 0.38, blue: 0.30, alpha: 1).setStroke(); check.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Smail/Assets.xcassets/AppIcon.appiconset/Icon.png"))
