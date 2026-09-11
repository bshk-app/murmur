// Run from Applications/iOS: swift PageTranslation/Artwork/GenerateActionIcon.swift
// A vector version of Murmator's cat mark. Action extensions render alpha as a mask:
// never add the containing app icon's opaque background to these images.
import AppKit

let output = URL(fileURLWithPath: "PageTranslation/Resources/ActionAssets.xcassets/ActionIcon.appiconset")
let entries: [(String, String, Int)] = [
    ("iphone", "20x20", 2), ("iphone", "20x20", 3),
    ("iphone", "29x29", 2), ("iphone", "29x29", 3),
    ("iphone", "40x40", 2), ("iphone", "40x40", 3),
    ("iphone", "60x60", 2), ("iphone", "60x60", 3),
    ("ipad", "20x20", 1), ("ipad", "20x20", 2),
    ("ipad", "29x29", 1), ("ipad", "29x29", 2),
    ("ipad", "40x40", 1), ("ipad", "40x40", 2),
    ("ipad", "76x76", 1), ("ipad", "76x76", 2),
    ("ipad", "83.5x83.5", 2), ("ios-marketing", "1024x1024", 1)
]
var images: [[String: String]] = []
for (idiom, size, scale) in entries {
    let pixels = Int(Double(size.components(separatedBy: "x")[0])! * Double(scale))
    let filename = "action-cat-\(pixels).png"
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 100, y: CGFloat(pixels) / 100)
    context.translateBy(x: 0, y: 100)
    context.scaleBy(x: 1, y: -1)
    context.setStrokeColor(CGColor(gray: 0, alpha: 1))
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.setLineWidth(4.3)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    let cat = CGMutablePath()
    cat.move(to: CGPoint(x: 17, y: 42))
    cat.addCurve(to: CGPoint(x: 21, y: 18), control1: CGPoint(x: 17, y: 29), control2: CGPoint(x: 19, y: 16))
    cat.addCurve(to: CGPoint(x: 36, y: 29), control1: CGPoint(x: 24, y: 18), control2: CGPoint(x: 32, y: 25))
    cat.addQuadCurve(to: CGPoint(x: 64, y: 29), control: CGPoint(x: 50, y: 24))
    cat.addCurve(to: CGPoint(x: 79, y: 18), control1: CGPoint(x: 68, y: 25), control2: CGPoint(x: 76, y: 18))
    cat.addCurve(to: CGPoint(x: 83, y: 42), control1: CGPoint(x: 81, y: 16), control2: CGPoint(x: 83, y: 29))
    cat.addCurve(to: CGPoint(x: 86, y: 58), control1: CGPoint(x: 86, y: 49), control2: CGPoint(x: 87, y: 53))
    cat.addCurve(to: CGPoint(x: 50, y: 84), control1: CGPoint(x: 85, y: 74), control2: CGPoint(x: 70, y: 84))
    cat.addCurve(to: CGPoint(x: 14, y: 58), control1: CGPoint(x: 30, y: 84), control2: CGPoint(x: 15, y: 74))
    cat.addCurve(to: CGPoint(x: 17, y: 42), control1: CGPoint(x: 13, y: 53), control2: CGPoint(x: 14, y: 49))
    cat.closeSubpath()
    context.addPath(cat)
    context.strokePath()
    context.fillEllipse(in: CGRect(x: 30, y: 49, width: 9, height: 10))
    context.fillEllipse(in: CGRect(x: 61, y: 49, width: 9, height: 10))
    let nose = CGMutablePath()
    nose.move(to: CGPoint(x: 47, y: 62))
    nose.addQuadCurve(to: CGPoint(x: 53, y: 62), control: CGPoint(x: 50, y: 61.5))
    nose.addQuadCurve(to: CGPoint(x: 50, y: 67), control: CGPoint(x: 56, y: 62))
    nose.addQuadCurve(to: CGPoint(x: 47, y: 62), control: CGPoint(x: 44, y: 62))
    context.addPath(nose)
    context.fillPath()
    let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    try png.write(to: output.appendingPathComponent(filename))
    images.append(["idiom": idiom, "size": size, "scale": "\(scale)x", "filename": filename])
}
let catalog: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
