// Draws the app icon in every theme color.
//
//   swift Scripts/generate-icons.swift ToWatchDB/Resources/Assets.xcassets
//
// For each color it writes:
//   - IconPreview-<Name>.imageset: the macOS-shaped icon, for Settings and the macOS Dock icon.
//   - AppIcon-<Name>.appiconset (not Coral): a full-bleed opaque iOS alternate icon.
// Coral is the primary icon (AppIcon.appiconset), which this script leaves alone.
import AppKit

struct Theme {
    let name: String
    let dark: (CGFloat, CGFloat, CGFloat)
    let light: (CGFloat, CGFloat, CGFloat)
}

let themes = [
    Theme(name: "Coral", dark: (0.18, 0.13, 0.42), light: (0.93, 0.36, 0.36)),
    Theme(name: "Orange", dark: (0.36, 0.16, 0.06), light: (1.00, 0.58, 0.00)),
    Theme(name: "Yellow", dark: (0.33, 0.22, 0.02), light: (1.00, 0.80, 0.00)),
    Theme(name: "Green", dark: (0.04, 0.24, 0.14), light: (0.20, 0.78, 0.35)),
    Theme(name: "Teal", dark: (0.03, 0.22, 0.27), light: (0.19, 0.69, 0.78)),
    Theme(name: "Blue", dark: (0.05, 0.12, 0.36), light: (0.00, 0.48, 1.00)),
    Theme(name: "Indigo", dark: (0.10, 0.08, 0.32), light: (0.35, 0.34, 0.84)),
    Theme(name: "Purple", dark: (0.22, 0.07, 0.33), light: (0.69, 0.32, 0.87)),
    Theme(name: "Pink", dark: (0.32, 0.06, 0.18), light: (1.00, 0.18, 0.33)),
    Theme(name: "Graphite", dark: (0.12, 0.12, 0.14), light: (0.56, 0.56, 0.58)),
]

func color(_ c: (CGFloat, CGFloat, CGFloat), _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: alpha)
}

/// `fullBleed` is the square, opaque iOS shape; otherwise the inset, rounded macOS shape.
func draw(_ theme: Theme, size: Int, fullBleed: Bool) -> Data {
    // iOS icons must have no alpha channel.
    let alpha: CGImageAlphaInfo = fullBleed ? .noneSkipLast : .premultipliedLast
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue)!
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

    let inset: CGFloat = fullBleed ? 0 : 100
    let body = NSRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    let radius: CGFloat = fullBleed ? 0 : 185
    NSGradient(colors: [color(theme.dark), color(theme.light)])!
        .draw(in: NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius), angle: -60)

    // Stacked poster cards.
    func card(_ r: NSRect, _ alpha: CGFloat, _ angle: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: r.midX, yBy: r.midY); t.rotate(byDegrees: angle); t.translateX(by: -r.midX, yBy: -r.midY)
        t.concat()
        NSColor(white: 1, alpha: alpha).setFill()
        NSBezierPath(roundedRect: r, xRadius: 36, yRadius: 36).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    card(NSRect(x: 330, y: 300, width: 330, height: 440), 0.35, 12)
    card(NSRect(x: 350, y: 290, width: 330, height: 440), 1.0, -4)

    // Play triangle and a progress bar on the front card.
    let triangle = NSBezierPath()
    triangle.move(to: NSPoint(x: 470, y: 590)); triangle.line(to: NSPoint(x: 470, y: 450))
    triangle.line(to: NSPoint(x: 590, y: 520)); triangle.close()
    color(theme.light).setFill(); triangle.fill()
    color(theme.dark, 0.25).setFill()
    NSBezierPath(roundedRect: NSRect(x: 405, y: 360, width: 220, height: 26), xRadius: 13, yRadius: 13).fill()
    color(theme.dark).setFill()
    NSBezierPath(roundedRect: NSRect(x: 405, y: 360, width: 140, height: 26), xRadius: 13, yRadius: 13).fill()

    NSGraphicsContext.restoreGraphicsState()
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

func write(_ json: String, to url: URL) throws {
    try json.write(to: url, atomically: true, encoding: .utf8)
}

let catalog = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "ToWatchDB/Resources/Assets.xcassets")
let fm = FileManager.default

for theme in themes {
    let preview = catalog.appending(path: "IconPreview-\(theme.name).imageset")
    try fm.createDirectory(at: preview, withIntermediateDirectories: true)
    try draw(theme, size: 512, fullBleed: false).write(to: preview.appending(path: "icon.png"))
    try write("""
    {"images":[{"filename":"icon.png","idiom":"universal"}],"info":{"author":"xcode","version":1}}
    """, to: preview.appending(path: "Contents.json"))

    guard theme.name != "Coral" else { continue }
    let icon = catalog.appending(path: "AppIcon-\(theme.name).appiconset")
    try fm.createDirectory(at: icon, withIntermediateDirectories: true)
    try draw(theme, size: 1024, fullBleed: true).write(to: icon.appending(path: "icon_ios_1024.png"))
    try write("""
    {"images":[{"filename":"icon_ios_1024.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
    """, to: icon.appending(path: "Contents.json"))
}
print("Wrote \(themes.count) previews and \(themes.count - 1) alternate icons to \(catalog.path)")
