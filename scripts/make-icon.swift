// Draws the app icon: a golden ear of wheat, with one fallen grain, on a warm dark tile.
//
// Usage: swift scripts/make-icon.swift [output.png]   (default: build/AppIcon-1024.png)
// scripts/make-icon.sh turns the PNG into Resources/AppIcon.icns.
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "build/AppIcon-1024.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

/// A pointed oval ("almond") centered at `center`, pointing along `angle` (radians, y-down).
func grain(center: CGPoint, length: CGFloat, width: CGFloat, angle: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let half = length / 2
    path.move(to: CGPoint(x: -half, y: 0))
    path.addCurve(to: CGPoint(x: half, y: 0), control1: CGPoint(x: -half * 0.45, y: -width * 0.75),
                  control2: CGPoint(x: half * 0.55, y: -width * 0.55))
    path.addCurve(to: CGPoint(x: -half, y: 0), control1: CGPoint(x: half * 0.55, y: width * 0.55),
                  control2: CGPoint(x: -half * 0.45, y: width * 0.75))
    var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle)
    return path.copy(using: &transform)!
}

/// Point and tangent angle on a cubic Bézier.
func bezier(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> (CGPoint, CGFloat) {
    let u = 1 - t
    let point = CGPoint(
        x: u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
        y: u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y)
    let dx = 3 * u * u * (p1.x - p0.x) + 6 * u * t * (p2.x - p1.x) + 3 * t * t * (p3.x - p2.x)
    let dy = 3 * u * u * (p1.y - p0.y) + 6 * u * t * (p2.y - p1.y) + 3 * t * t * (p3.y - p2.y)
    return (point, atan2(dy, dx))
}

let context = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Work in y-down coordinates.
context.translateBy(x: 0, y: size)
context.scaleBy(x: 1, y: -1)

// MARK: Tile

let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = CGPath(roundedRect: tileRect, cornerWidth: 186, cornerHeight: 186, transform: nil)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: color(0x000000, 0.35))
context.addPath(tile)
context.setFillColor(color(0x221E1A))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(tile)
context.clip()
context.drawLinearGradient(gradient([color(0x35302A), color(0x1B1815)], [0, 1]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
// Warm glow behind the wheat.
context.drawRadialGradient(gradient([color(0xE8B964, 0.22), color(0xE8B964, 0)], [0, 1]),
                           startCenter: CGPoint(x: 540, y: 470), startRadius: 0,
                           endCenter: CGPoint(x: 540, y: 470), endRadius: 400, options: [])
// Soft sheen on the upper half.
context.drawLinearGradient(gradient([color(0xFFFFFF, 0.07), color(0xFFFFFF, 0)], [0, 1]),
                           start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 520), options: [])
context.restoreGState()

// Hairline edge.
context.addPath(CGPath(roundedRect: tileRect.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
context.setStrokeColor(color(0xFFFFFF, 0.08))
context.setLineWidth(3)
context.strokePath()

// MARK: Wheat

let gold = gradient([color(0xF7E2AE), color(0xE2B45E), color(0xB98432)], [0, 0.55, 1])
let stem = (CGPoint(x: 452, y: 812), CGPoint(x: 492, y: 640), CGPoint(x: 520, y: 430), CGPoint(x: 600, y: 238))

// Stem.
let stemPath = CGMutablePath()
stemPath.move(to: stem.0)
stemPath.addCurve(to: stem.3, control1: stem.1, control2: stem.2)

// Grains and awns along the upper part of the stem, alternating sides, smaller toward the tip.
let grains = CGMutablePath()
let awns = CGMutablePath()
let steps = 7
for i in 0..<steps {
    let t = 0.40 + CGFloat(i) * 0.085
    let (point, tangent) = bezier(stem.0, stem.1, stem.2, stem.3, t)
    let scale = 1 - CGFloat(i) * 0.075
    let length: CGFloat = 112 * scale
    let width: CGFloat = 44 * scale
    for side: CGFloat in [-1, 1] {
        let angle = tangent + side * 0.62
        let center = CGPoint(x: point.x + cos(angle) * length * 0.42, y: point.y + sin(angle) * length * 0.42)
        grains.addPath(grain(center: center, length: length, width: width, angle: angle))
        let tip = CGPoint(x: center.x + cos(angle) * length * 0.5, y: center.y + sin(angle) * length * 0.5)
        let awnAngle = angle - side * 0.18
        awns.move(to: tip)
        awns.addLine(to: CGPoint(x: tip.x + cos(awnAngle) * 70 * scale, y: tip.y + sin(awnAngle) * 70 * scale))
    }
}
// Terminal grain at the tip.
let (tipPoint, tipAngle) = bezier(stem.0, stem.1, stem.2, stem.3, 1)
let tipCenter = CGPoint(x: tipPoint.x + cos(tipAngle) * 30, y: tipPoint.y + sin(tipAngle) * 30)
grains.addPath(grain(center: tipCenter, length: 78, width: 30, angle: tipAngle))
awns.move(to: CGPoint(x: tipCenter.x + cos(tipAngle) * 39, y: tipCenter.y + sin(tipAngle) * 39))
awns.addLine(to: CGPoint(x: tipCenter.x + cos(tipAngle) * 92, y: tipCenter.y + sin(tipAngle) * 92))

// A slender leaf curving away from the lower stem.
let leaf = CGMutablePath()
let leafBase = bezier(stem.0, stem.1, stem.2, stem.3, 0.16).0
leaf.move(to: leafBase)
leaf.addCurve(to: CGPoint(x: 316, y: 556), control1: CGPoint(x: leafBase.x - 70, y: leafBase.y - 120),
              control2: CGPoint(x: 352, y: 566))
leaf.addCurve(to: leafBase, control1: CGPoint(x: 400, y: 622), control2: CGPoint(x: leafBase.x - 8, y: leafBase.y - 36))

// The fallen grain: the one being "gleaned".
let fallen = grain(center: CGPoint(x: 646, y: 792), length: 74, width: 30, angle: -0.35)

func fillGold(_ path: CGPath, alpha: CGFloat = 1) {
    context.saveGState()
    context.setAlpha(alpha)
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(gold, start: CGPoint(x: 400, y: 200), end: CGPoint(x: 620, y: 860), options: [])
    context.restoreGState()
}

// Everything golden stays inside the tile.
context.saveGState()
context.addPath(CGPath(roundedRect: tileRect.insetBy(dx: 24, dy: 24), cornerWidth: 170, cornerHeight: 170, transform: nil))
context.clip()

// Soft glow under the golden parts.
context.saveGState()
context.setShadow(offset: .zero, blur: 24, color: color(0xE8B964, 0.35))
context.addPath(grains)
context.setFillColor(color(0xD8A64F, 0.9))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(awns)
context.setStrokeColor(color(0xEBC77E, 0.55))
context.setLineWidth(3)
context.setLineCap(.round)
context.strokePath()
context.restoreGState()

context.saveGState()
context.addPath(stemPath)
context.setStrokeColor(color(0xD9AA55))
context.setLineWidth(11)
context.setLineCap(.round)
context.strokePath()
context.restoreGState()

fillGold(leaf, alpha: 0.85)
fillGold(grains)
fillGold(fallen, alpha: 0.95)

context.restoreGState()  // tile clip

// MARK: Write

let image = context.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let url = URL(fileURLWithPath: output)
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
try rep.representation(using: .png, properties: [:])!.write(to: url)
print("Wrote \(output)")
