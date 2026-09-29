// Draws the Nimble Name app icon: a cream page with a Nimble Blue magic wand and sparkles.
// Follows "Nimble Icons style guide v2". Usage: swift scripts/generate_icon.swift <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let nimbleBlue = CGColor(srgbRed: 0, green: 154 / 255, blue: 214 / 255, alpha: 1)  // #009AD6
let deepBlue = CGColor(srgbRed: 0, green: 108 / 255, blue: 165 / 255, alpha: 1)    // #006CA5
let cream = CGColor(srgbRed: 250 / 255, green: 248 / 255, blue: 244 / 255, alpha: 1) // #FAF8F4

let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

// Background: diagonal gradient, Nimble Blue top-left to Deep Blue bottom-right
let gradient = CGGradient(colorsSpace: cs, colors: [nimbleBlue, deepBlue] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 1024, y: 0),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// 512 grid, top-left origin
ctx.translateBy(x: 0, y: 1024)
ctx.scaleBy(x: 2, y: -2)

/// Closed polygon with a corner radius per vertex: (x, y, radius).
func roundedPolygon(_ pts: [(CGFloat, CGFloat, CGFloat)]) -> CGPath {
    let path = CGMutablePath()
    let last = pts[pts.count - 1], first = pts[0]
    path.move(to: CGPoint(x: (last.0 + first.0) / 2, y: (last.1 + first.1) / 2))
    for i in pts.indices {
        let c = pts[i], n = pts[(i + 1) % pts.count]
        path.addArc(tangent1End: CGPoint(x: c.0, y: c.1), tangent2End: CGPoint(x: n.0, y: n.1), radius: c.2)
    }
    path.closeSubpath()
    return path
}

/// Four-point sparkle with a softly curved waist.
func sparkle(center cx: CGFloat, _ cy: CGFloat, radius r: CGFloat) -> CGPath {
    let d = r * 0.34 / sqrt(2)
    return roundedPolygon([
        (cx, cy - r, r * 0.06), (cx + d, cy - d, r * 0.5),
        (cx + r, cy, r * 0.06), (cx + d, cy + d, r * 0.5),
        (cx, cy + r, r * 0.06), (cx - d, cy + d, r * 0.5),
        (cx - r, cy, r * 0.06), (cx - d, cy - d, r * 0.5),
    ])
}

// Page: 272 x 336 at (120, 88), dog-eared top-right
let page = roundedPolygon([(120, 88, 72), (296, 88, 22), (392, 184, 22), (392, 424, 72), (120, 424, 72)])
ctx.setFillColor(cream)
ctx.addPath(page)
ctx.fillPath()

// Wand: round-capped stroke, bottom-left to top-right
ctx.setStrokeColor(nimbleBlue)
ctx.setLineWidth(46)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 182, y: 364))
ctx.addLine(to: CGPoint(x: 262, y: 284))
ctx.strokePath()

// Sparkles: a large one at the wand tip, a small one beside it
ctx.setFillColor(nimbleBlue)
ctx.addPath(sparkle(center: 302, 228, radius: 66))
ctx.addPath(sparkle(center: 198, 184, radius: 32))
ctx.fillPath()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(output)") }
print("wrote \(output)")
