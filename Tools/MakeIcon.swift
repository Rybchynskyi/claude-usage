import AppKit

// Renders the app icon into an .iconset directory, which `iconutil` then turns
// into AppIcon.icns. Generated at build time so the repository keeps no binaries.
//
//   swiftc Sources/Brand.swift Sources/Views.swift Tools/MakeIcon.swift -o makeicon
//   ./makeicon build/AppIcon.iconset

@main
enum MakeIcon {
static func icon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        // macOS icons sit in a rounded square with a margin around it.
        let body = rect.insetBy(dx: rect.width * 0.085, dy: rect.height * 0.085)
        let shape = NSBezierPath(roundedRect: body,
                                 xRadius: body.width * 0.2237,
                                 yRadius: body.width * 0.2237)
        shape.addClip()
        NSGradient(colors: [NSColor(hex: 0xE08E6B), NSColor(hex: 0xBE5C3C)])?
            .draw(in: body, angle: -90)

        // A soft diagonal sheen, so the face is not a flat slab of colour.
        NSGradient(colors: [NSColor(white: 1, alpha: 0.16), NSColor(white: 1, alpha: 0)])?
            .draw(in: body, angle: -60)

        let mark = ClaudeMark.image(size: body.width * 0.62, color: NSColor(hex: 0xFBF7EF))
        mark.draw(in: NSRect(x: body.midX - body.width * 0.31,
                             y: body.midY - body.width * 0.31,
                             width: body.width * 0.62, height: body.width * 0.62))
        return true
    }
}

static func main() {
guard let directory = CommandLine.arguments.dropFirst().first else {
    FileHandle.standardError.write(Data("usage: makeicon <out.iconset>\n".utf8))
    exit(2)
}
try! FileManager.default.createDirectory(atPath: directory,
                                         withIntermediateDirectories: true)

// (point size, scale) pairs that iconutil expects.
let variants: [(CGFloat, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2),
                                  (128, 1), (128, 2), (256, 1), (256, 2),
                                  (512, 1), (512, 2)]
for (points, scale) in variants {
    let pixels = points * CGFloat(scale)
    let image = icon(size: pixels)
    guard let rep = NSBitmapImageRep(data: image.tiffRepresentation!),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    let suffix = scale == 1 ? "" : "@2x"
    let name = "icon_\(Int(points))x\(Int(points))\(suffix).png"
    try! png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
}
}
}
