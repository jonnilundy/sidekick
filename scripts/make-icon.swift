// Draws the app icon. Run from the repo root:
//   swift scripts/make-icon.swift            write assets/AppIcon.icns in the chosen style (STYLE below)
//   swift scripts/make-icon.swift --sheet    write build/icon-options.png with every style side by side
import AppKit

let STYLE = "paper"

struct Style {
    let name: String
    let top: NSColor
    let bottom: NSColor
    let symbol: String
    let symbolColors: [NSColor]
    let scale: CGFloat
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1) }
let clay = rgb(217, 120, 87)

let styles: [Style] = [
    Style(name: "clay", top: rgb(237, 148, 112), bottom: rgb(199, 97, 66), symbol: "sparkle", symbolColors: [.white], scale: 0.42),
    Style(name: "graphite", top: rgb(58, 58, 64), bottom: rgb(24, 24, 28), symbol: "sparkle", symbolColors: [clay], scale: 0.42),
    Style(name: "paper", top: rgb(255, 253, 249), bottom: rgb(236, 230, 220), symbol: "sparkle", symbolColors: [clay], scale: 0.42),
    Style(name: "bubble", top: rgb(237, 148, 112), bottom: rgb(199, 97, 66), symbol: "bubble.left.fill", symbolColors: [.white], scale: 0.40),
    Style(name: "sparkles", top: rgb(92, 104, 230), bottom: rgb(52, 46, 150), symbol: "sparkles", symbolColors: [.white], scale: 0.44),
    Style(name: "edge", top: rgb(40, 40, 46), bottom: rgb(18, 18, 22), symbol: "sidebar.right", symbolColors: [clay], scale: 0.40),
]

func render(_ style: Style, size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [style.top, style.bottom])!.draw(in: path, angle: -90)
    // A faint top highlight, like light on a material edge.
    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()
    if style.symbol == "bubble.left.fill" {
        drawSymbol("bubble.left.fill", colors: style.symbolColors, pointSize: s * style.scale, in: s, dy: 0)
        drawSymbol("sparkle", colors: [style.bottom], pointSize: s * 0.17, in: s, dy: s * 0.035)
    } else {
        drawSymbol(style.symbol, colors: style.symbolColors, pointSize: s * style.scale, in: s, dy: 0)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func drawSymbol(_ name: String, colors: [NSColor], pointSize: CGFloat, in s: CGFloat, dy: CGFloat) {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold).applying(.init(paletteColors: colors))
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
    let size = symbol.size
    symbol.draw(in: NSRect(x: (s - size.width) / 2, y: (s - size.height) / 2 + dy, width: size.width, height: size.height))
}

func png(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

if CommandLine.arguments.contains("--sheet") {
    let cell = 300, label = 44, cols = 3
    let rows = (styles.count + cols - 1) / cols
    let sheet = NSImage(size: NSSize(width: cell * cols, height: (cell + label) * rows))
    sheet.lockFocus()
    NSColor(white: 0.96, alpha: 1).setFill()
    NSRect(origin: .zero, size: sheet.size).fill()
    for (i, style) in styles.enumerated() {
        let col = i % cols, row = i / cols
        let x = CGFloat(col * cell), y = sheet.size.height - CGFloat((row + 1) * (cell + label))
        let image = NSImage(size: NSSize(width: 256, height: 256))
        image.addRepresentation(render(style, size: 512))
        image.draw(in: NSRect(x: x + 22, y: y + CGFloat(label), width: 256, height: 256))
        let text = "\(i + 1). \(style.name)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20, weight: .medium), .foregroundColor: NSColor.darkGray]
        let w = text.size(withAttributes: attrs).width
        text.draw(at: NSPoint(x: x + (CGFloat(cell) - w) / 2, y: y + 12), withAttributes: attrs)
    }
    sheet.unlockFocus()
    let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
    try! FileManager.default.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
    let out = root.appendingPathComponent("build/icon-options.png")
    try! png(rep).write(to: out)
    print("wrote \(out.path)")
    exit(0)
}

let style = styles.first { $0.name == STYLE }!
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! png(render(style, size: base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! png(render(style, size: base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = root.appendingPathComponent("assets/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! task.run()
task.waitUntilExit()
print("wrote \(out.path) (\(STYLE))")
