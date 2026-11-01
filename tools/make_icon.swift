// Draws the NotchGuard app icon (a shield with a MacBook notch and its camera dot) and builds
// assets/AppIcon.icns. Run: swift tools/make_icon.swift
import AppKit

let S: CGFloat = 1024
/// Top-left coordinates, so the shapes read like the design.
func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: S - y) }
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Background: the macOS icon grid's rounded square (824 pt inside 1024, with room for the drop shadow).
let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.45))
ctx.addPath(tile); ctx.setFillColor(rgb(0x10132A)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tile); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x232A55), rgb(0x0A0C1C)]), start: p(512, 100), end: p(512, 924), options: [])
// A soft glow behind the shield.
ctx.drawRadialGradient(gradient([rgb(0x3FD8C8, 0.28), rgb(0x3FD8C8, 0)]), startCenter: p(512, 470), startRadius: 0,
                       endCenter: p(512, 470), endRadius: 420, options: [])
ctx.restoreGState()

// Shield: a flat top edge (the top of a screen) curving to a point.
let shield = CGMutablePath()
shield.move(to: p(345, 250))
shield.addLine(to: p(679, 250))
shield.addQuadCurve(to: p(724, 295), control: p(724, 250))
shield.addLine(to: p(724, 515))
shield.addCurve(to: p(512, 805), control1: p(724, 660), control2: p(625, 752))
shield.addCurve(to: p(300, 515), control1: p(399, 752), control2: p(300, 660))
shield.addLine(to: p(300, 295))
shield.addQuadCurve(to: p(345, 250), control: p(300, 250))
shield.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0x000000, 0.5))
ctx.addPath(shield); ctx.setFillColor(rgb(0x2E7BEF)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(shield); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x5BEAD8), rgb(0x2F8CF0), rgb(0x3D4FE0)]), start: p(512, 250), end: p(512, 805), options: [])
// Glass: a bright sheen over the upper half.
ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.35), rgb(0xFFFFFF, 0)]), start: p(512, 250), end: p(512, 540), options: [])
ctx.restoreGState()
// Thin light rim.
ctx.addPath(shield); ctx.setStrokeColor(rgb(0xFFFFFF, 0.35)); ctx.setLineWidth(5); ctx.strokePath()

// The notch, hanging from the shield's top edge.
let notch = CGMutablePath()
notch.move(to: p(420, 248))
notch.addLine(to: p(604, 248))
notch.addLine(to: p(604, 290))
notch.addQuadCurve(to: p(572, 322), control: p(604, 322))
notch.addLine(to: p(452, 322))
notch.addQuadCurve(to: p(420, 290), control: p(420, 322))
notch.closeSubpath()
ctx.addPath(notch); ctx.setFillColor(rgb(0x05060C)); ctx.fillPath()

// Camera dot, on and watching.
ctx.drawRadialGradient(gradient([rgb(0x4DFF9A, 0.8), rgb(0x4DFF9A, 0)]), startCenter: p(512, 285), startRadius: 0,
                       endCenter: p(512, 285), endRadius: 34, options: [])
ctx.addEllipse(in: CGRect(x: 512 - 11, y: S - 285 - 11, width: 22, height: 22))
ctx.setFillColor(rgb(0x7CFFB6)); ctx.fillPath()

// Write the iconset and compile it.
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let set = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
let full = ctx.makeImage()!
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.interpolationQuality = .high
        c.draw(full, in: CGRect(x: 0, y: 0, width: px, height: px))
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        let data = NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!
        try! data.write(to: set.appendingPathComponent(name))
    }
}
try! NSBitmapImageRep(cgImage: full).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("build/AppIcon-1024.png"))
let assets = root.appendingPathComponent("assets")
try! FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote assets/AppIcon.icns" : "iconutil failed")
