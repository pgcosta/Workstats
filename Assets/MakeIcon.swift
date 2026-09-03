import AppKit

// Generates WorkStats master icon (1024px PNG) -> see build-app.sh for .icns.
// Design: deep-indigo squircle, three white bars (focus/procrast/accompl),
// orange badge dot = the attention nudge.
let size = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

let s = CGFloat(size)
// Squircle background
let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                       xRadius: s * 0.225, yRadius: s * 0.225)
let grad = NSGradient(colors: [
    NSColor(red: 0.36, green: 0.34, blue: 0.90, alpha: 1),  // indigo top
    NSColor(red: 0.16, green: 0.14, blue: 0.45, alpha: 1),  // deep navy bottom
])!
grad.draw(in: bg, angle: 90)

// Bars (white, varying heights)
struct Bar { var x: CGFloat; var w: CGFloat; var h: CGFloat }
let bars = [
    Bar(x: 0.24, w: 0.13, h: 0.34),
    Bar(x: 0.435, w: 0.13, h: 0.50),
    Bar(x: 0.63, w: 0.13, h: 0.41),
]
NSColor.white.setFill()
for b in bars {
    let r = NSBezierPath(roundedRect: NSRect(
        x: s * b.x, y: s * 0.24, width: s * b.w, height: s * b.h
    ), xRadius: s * 0.03, yRadius: s * 0.03)
    r.fill()
}

// Orange badge dot, top-right
let dotR = s * 0.075
let dot = NSBezierPath(ovalIn: NSRect(
    x: s * 0.70, y: s * 0.68, width: dotR * 2, height: dotR * 2))
NSColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 1).setFill()
dot.fill()
// White ring around dot
let ring = NSBezierPath(ovalIn: NSRect(
    x: s * 0.70 - s * 0.014, y: s * 0.68 - s * 0.014,
    width: dotR * 2 + s * 0.028, height: dotR * 2 + s * 0.028))
ring.lineWidth = s * 0.014
NSColor.white.setStroke()
ring.stroke()

img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
let out = URL(fileURLWithPath: "Assets/AppIcon-master.png")
try png.write(to: out)
print("wrote \(out.path)")
