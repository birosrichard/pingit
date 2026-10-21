#!/usr/bin/env swift
// Vector master and asset exporter. Run from the repository root with:
// swift scripts/generate-icons.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let artwork = root.appendingPathComponent("artwork/icons")
let catalog = root.appendingPathComponent("pingit/Resources/Assets.xcassets")
let blue = CGColor(srgbRed: 0.02, green: 0.39, blue: 0.91, alpha: 1)
let paper = CGColor(srgbRed: 0.975, green: 0.98, blue: 0.99, alpha: 1)
let black = CGColor(gray: 0, alpha: 1)
let white = CGColor(gray: 1, alpha: 1)
let info: [String: Any] = ["author": "xcode", "version": 1]

func json(_ object: [String: Any], at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}
func ellipse(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
    c.fillEllipse(in: CGRect(x: x-r, y: y-r, width: r*2, height: r*2))
}
func line(_ c: CGContext, _ points: [CGPoint], width: CGFloat) {
    c.setLineWidth(width)
    c.setLineCap(.round)
    c.setLineJoin(.round)
    c.addLines(between: points)
    c.strokePath()
}
func node(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, radius: CGFloat, width: CGFloat) {
    c.setLineWidth(width)
    c.strokeEllipse(in: CGRect(x: x-radius, y: y-radius, width: radius*2, height: radius*2))
}

// One bell silhouette shared by the app and header; coordinates use a 100-unit grid.
func brand(_ c: CGContext, small: Bool = false, background: Bool = true) {
    if background {
        c.setFillColor(paper)
        c.addPath(CGPath(roundedRect: CGRect(x: 6, y: 6, width: 88, height: 88),
                         cornerWidth: 20, cornerHeight: 20, transform: nil))
        c.fillPath()
    }
    c.setFillColor(blue)
    c.addPath(CGPath(roundedRect: CGRect(x: 44, y: 23, width: 8, height: 12),
                         cornerWidth: 4, cornerHeight: 4, transform: nil))
    c.fillPath()
    c.move(to: CGPoint(x: 25, y: 70))
    c.addCurve(to: CGPoint(x: 30, y: 53), control1: CGPoint(x: 29, y: 65), control2: CGPoint(x: 30, y: 60))
    c.addLine(to: CGPoint(x: 30, y: 47))
    c.addCurve(to: CGPoint(x: 48, y: 29), control1: CGPoint(x: 30, y: 36), control2: CGPoint(x: 37, y: 29))
    c.addCurve(to: CGPoint(x: 66, y: 47), control1: CGPoint(x: 59, y: 29), control2: CGPoint(x: 66, y: 36))
    c.addLine(to: CGPoint(x: 66, y: 53))
    c.addCurve(to: CGPoint(x: 71, y: 70), control1: CGPoint(x: 66, y: 60), control2: CGPoint(x: 67, y: 65))
    c.addQuadCurve(to: CGPoint(x: 69, y: 73), control: CGPoint(x: 73, y: 73))
    c.addLine(to: CGPoint(x: 27, y: 73))
    c.addQuadCurve(to: CGPoint(x: 25, y: 70), control: CGPoint(x: 23, y: 73))
    c.fillPath()
    c.fillEllipse(in: CGRect(x: 42, y: 76, width: 12, height: 7))

    // The knockout is transparent in the standalone header mark.
    let radius: CGFloat = small ? 17 : 15
    c.saveGState()
    c.setBlendMode(.clear)
    ellipse(c, 70, 33, radius + 2)
    c.restoreGState()
    if background {
        c.setFillColor(paper)
        ellipse(c, 70, 33, radius + 2)
    }
    c.setFillColor(blue)
    ellipse(c, 70, 33, radius)
    c.setStrokeColor(white)
    let weight: CGFloat = small ? 2.6 : 2.2
    let r: CGFloat = small ? 2.5 : 2.3
    line(c, [CGPoint(x: 64, y: 29+r), CGPoint(x: 64, y: 40-r)], width: weight)
    node(c, 64, 27, radius: r, width: weight)
    node(c, 64, 40, radius: r, width: weight)
    node(c, 76, 40, radius: r, width: weight)
    c.setLineWidth(weight)
    c.move(to: CGPoint(x: 76, y: 40-r))
    c.addLine(to: CGPoint(x: 76, y: 32))
    c.addQuadCurve(to: CGPoint(x: 72, y: 27), control: CGPoint(x: 76, y: 27))
    c.addLine(to: CGPoint(x: 70, y: 27))
    c.strokePath()
    line(c, [CGPoint(x: 72, y: 24.5), CGPoint(x: 69.5, y: 27), CGPoint(x: 72, y: 29.5)], width: weight)
}

// Optical variant on a 20 × 18 pt grid. Larger badge and fewer details than the master.
func menu(_ c: CGContext) {
    c.setFillColor(black)
    c.fillEllipse(in: CGRect(x: 7, y: 1, width: 2, height: 3))
    c.move(to: CGPoint(x: 2, y: 14))
    c.addCurve(to: CGPoint(x: 3.5, y: 8), control1: CGPoint(x: 3.5, y: 12), control2: CGPoint(x: 3.5, y: 10))
    c.addCurve(to: CGPoint(x: 8, y: 3), control1: CGPoint(x: 3.5, y: 4.7), control2: CGPoint(x: 5.2, y: 3))
    c.addCurve(to: CGPoint(x: 12.5, y: 8), control1: CGPoint(x: 10.8, y: 3), control2: CGPoint(x: 12.5, y: 4.7))
    c.addCurve(to: CGPoint(x: 14, y: 14), control1: CGPoint(x: 12.5, y: 10), control2: CGPoint(x: 12.5, y: 12))
    c.addQuadCurve(to: CGPoint(x: 13.5, y: 15), control: CGPoint(x: 14.7, y: 15))
    c.addLine(to: CGPoint(x: 2.5, y: 15))
    c.addQuadCurve(to: CGPoint(x: 2, y: 14), control: CGPoint(x: 1.3, y: 15))
    c.fillPath()
    c.fillEllipse(in: CGRect(x: 6.5, y: 16, width: 3, height: 1.5))
    c.saveGState()
    c.setBlendMode(.clear)
    ellipse(c, 14, 5, 5.3)
    c.restoreGState()
    ellipse(c, 14, 5, 4.5)
    // Cut the PR symbol out of the black badge so the system can tint all artwork.
    c.saveGState()
    c.setBlendMode(.clear)
    c.setStrokeColor(black)
    line(c, [CGPoint(x: 12.2, y: 3.4), CGPoint(x: 12.2, y: 6.8)], width: 0.9)
    node(c, 12.2, 2.9, radius: 0.65, width: 0.8)
    node(c, 12.2, 7, radius: 0.65, width: 0.8)
    node(c, 16, 7, radius: 0.65, width: 0.8)
    line(c, [CGPoint(x: 16, y: 6.3), CGPoint(x: 16, y: 4.3), CGPoint(x: 14.5, y: 3)], width: 0.9)
    line(c, [CGPoint(x: 15.7, y: 2.9), CGPoint(x: 14.4, y: 2.9), CGPoint(x: 14.4, y: 4.2)], width: 0.8)
    c.restoreGState()
}

func bitmap(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
    let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: 0, y: CGFloat(height))
    c.scaleBy(x: 1, y: -1)
    draw(c)
    return c.makeImage()!
}
func png(_ image: CGImage, at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
}
func appImage(_ pixels: Int, small: Bool) -> CGImage {
    bitmap(width: pixels, height: pixels) { c in
        c.scaleBy(x: CGFloat(pixels)/100, y: CGFloat(pixels)/100)
        brand(c, small: small)
    }
}
func pdf(_ name: String, width: CGFloat, height: CGFloat, draw: (CGContext) -> Void) {
    var box = CGRect(x: 0, y: 0, width: width, height: height)
    let c = CGContext(artwork.appendingPathComponent(name).appendingPathExtension("pdf") as CFURL, mediaBox: &box, nil)!
    c.beginPDFPage(nil)
    c.translateBy(x: 0, y: height)
    c.scaleBy(x: 1, y: -1)
    draw(c)
    c.endPDFPage()
    c.closePDF()
}
try FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)
pdf("AppIcon-master", width: 1024, height: 1024) { c in
    c.scaleBy(x: 10.24, y: 10.24)
    brand(c)
}
pdf("MenuBar-master", width: 20, height: 18, draw: menu)
try png(appImage(1024, small: false), at: artwork.appendingPathComponent("AppIcon-1024.png"))
try json(["info": info], at: catalog.appendingPathComponent("Contents.json"))
var icons: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try png(appImage(size*scale, small: size <= 32), at: catalog.appendingPathComponent("AppIcon.appiconset/\(filename)"))
        icons.append(["filename": filename, "idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x"])
    }
}
try json(["images": icons, "info": info], at: catalog.appendingPathComponent("AppIcon.appiconset/Contents.json"))
for (name, width, height) in [("MenuBarIcon", 20, 18), ("PingitMark", 32, 32)] {
    var images: [[String: String]] = []
    for scale in [1, 2] {
        let filename = "\(name)\(scale == 2 ? "@2x" : "").png"
        let image = bitmap(width: width*scale, height: height*scale) { c in
            if name == "MenuBarIcon" {
                c.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                menu(c)
            } else {
                c.scaleBy(x: CGFloat(width*scale)/100, y: CGFloat(height*scale)/100)
                brand(c, small: true, background: false)
            }
        }
        try png(image, at: catalog.appendingPathComponent("\(name).imageset/\(filename)"))
        images.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x"])
        if name == "MenuBarIcon" {
            let rep = NSBitmapImageRep(cgImage: image)
            assert(rep.hasAlpha && rep.pixelsWide == 20*scale && rep.pixelsHigh == 18*scale)
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    let color = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    assert(color.alphaComponent == 0 || max(color.redComponent, color.greenComponent, color.blueComponent) < 0.01)
                }
            }
        }
    }
    try json(["images": images, "info": info,
              "properties": ["template-rendering-intent": name == "MenuBarIcon" ? "template" : "original"]],
             at: catalog.appendingPathComponent("\(name).imageset/Contents.json"))
}

func place(_ c: CGContext, image: CGImage, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
    c.saveGState()
    c.translateBy(x: x, y: y+height)
    c.scaleBy(x: 1, y: -1)
    c.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    c.restoreGState()
}
let sheet = bitmap(width: 1000, height: 760) { c in
    c.setFillColor(CGColor(gray: 0.92, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: 1000, height: 760))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
    func label(_ text: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 14, color: NSColor = .darkGray) {
        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color])
    }
    label("Pingit / Icon system", 36, 28, size: 24)
    place(c, image: appImage(512, small: false), x: 20, y: 80, width: 512, height: 512)
    label("App icon · 512 px", 50, 608)
    place(c, image: appImage(128, small: false), x: 590, y: 110, width: 128, height: 128)
    label("128 px", 600, 254)
    place(c, image: appImage(32, small: true), x: 790, y: 154, width: 32, height: 32)
    label("32 px · optical variant", 770, 254)
    place(c, image: appImage(16, small: true), x: 906, y: 162, width: 16, height: 16)
    label("16 px", 896, 202)
    for (index, dark) in [false, true].enumerated() {
        let y: CGFloat = 340 + CGFloat(index)*108
        c.setFillColor(CGColor(gray: dark ? 0.12 : 0.99, alpha: 1))
        c.fill(CGRect(x: 578, y: y, width: 380, height: 38))
        let icon = bitmap(width: 40, height: 36) { m in
            m.scaleBy(x: 2, y: 2)
            menu(m)
            if dark {
                m.setBlendMode(.sourceIn)
                m.setFillColor(white)
                m.fill(CGRect(x: 0, y: 0, width: 20, height: 18))
            }
        }
        place(c, image: icon, x: 602, y: y+10, width: 20, height: 18)
        label("9:41", 892, y+10, size: 14, color: dark ? .white : .black)
        label("Menu bar · 18 pt · \(dark ? "dark" : "light") appearance", 590, y+50)
    }
    label("Header mark · 32 pt", 590, 602)
    let mark = NSImage(contentsOf: catalog.appendingPathComponent("PingitMark.imageset/PingitMark@2x.png"))!
    mark.draw(in: NSRect(x: 590, y: 640, width: 32, height: 32))
    label("pingit", 632, 645, size: 17)
    label("Flat color / transparent template / Retina 1× + 2×", 36, 708)
    NSGraphicsContext.restoreGraphicsState()
}
try png(sheet, at: artwork.appendingPathComponent("contact-sheet.png"))
print("Generated vector masters, 10 app icon slots, 1×/2× template and header assets, and contact sheet.")
