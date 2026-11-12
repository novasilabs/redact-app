// Renders Redact's app icon: a near-black asterisk on the lime accent, on the macOS icon grid.
//   swift scripts/make-icon.swift            writes Resources/AppIcon.icns (+ Resources/AppIcon-1024.png)
// The asterisk geometry matches `AsteriskShape` in Sources/RedactApp/Theme.swift; keep them in sync.
import AppKit
import CoreGraphics

/// OKLCH → sRGB, same conversion as Theme.swift.
func oklch(_ l: Double, _ c: Double, _ h: Double) -> CGColor {
    let hr = h * .pi / 180
    let a = c * cos(hr), b = c * sin(hr)
    let l_ = l + 0.3963377774 * a + 0.2158037573 * b
    let m_ = l - 0.1055613458 * a - 0.0638541728 * b
    let s_ = l - 0.0894841775 * a - 1.2914855480 * b
    let (L, M, S) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
    func gamma(_ x: Double) -> CGFloat {
        let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        return CGFloat(min(max(v, 0), 1))
    }
    return CGColor(srgbRed: gamma(4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S),
                   green: gamma(-1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S),
                   blue: gamma(-0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S), alpha: 1)
}

// Lime tile, lit from above.
let limeTop = oklch(0.93, 0.17, 125)
let limeBottom = oklch(0.80, 0.19, 132)
let limeRim = oklch(0.66, 0.16, 135)
// Near-black mark: face lit from above, side darker.
let inkTop = oklch(0.34, 0.03, 128)
let inkBottom = oklch(0.13, 0.02, 128)
let inkSide = oklch(0.08, 0.015, 128)

/// Mark geometry, as fractions of the tile width. Mirrored by `AsteriskShape` in Theme.swift.
struct Mark {
    static let outer: CGFloat = 0.335     // arm tip distance from the centre
    static let inner: CGFloat = 0.06      // centre gap: six separate arms, a masked character
    static let width: CGFloat = 0.112     // arm thickness
    static let angles: [Double] = [90, 30, -30, -90, -150, 150]
}

/// Six separate rounded arms around an open centre.
func asterisk(center: CGPoint, tile: CGFloat, small: Bool) -> CGPath {
    let path = CGMutablePath()
    let outer = tile * Mark.outer
    let inner = small ? 0 : tile * Mark.inner
    let width = tile * (small ? 0.13 : Mark.width)
    for angle in Mark.angles {
        let arm = CGPath(roundedRect: CGRect(x: inner, y: -width / 2, width: outer - inner, height: width),
                         cornerWidth: width / 2, cornerHeight: width / 2, transform: nil)
        let t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: CGFloat(angle) * .pi / 180)
        path.addPath(arm, transform: t)
    }
    return path
}

func verticalGradient(_ ctx: CGContext, in rect: CGRect, top: CGColor, bottom: CGColor) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [bottom, top] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
}

func render(size: Int) -> CGImage {
    let s = CGFloat(size)
    let small = size <= 32
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS grid: 824/1024 body, centered. (CoreGraphics: y grows upwards.)
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225
    let tile = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // 1. Tile drop shadow.
    if !small {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.035, color: CGColor(gray: 0, alpha: 0.32))
        ctx.addPath(tile); ctx.setFillColor(limeBottom); ctx.fillPath()
        ctx.restoreGState()
    }

    // 2. Tile body: lit from above, gloss on the upper half, darker rim at the bottom.
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    verticalGradient(ctx, in: body, top: limeTop, bottom: limeBottom)
    if !small {
        let gloss = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.28)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gloss, start: CGPoint(x: body.midX, y: body.midY), end: CGPoint(x: body.midX, y: body.maxY), options: [])
        // Inner light along the top edge, inner shade along the bottom.
        var up = CGAffineTransform(translationX: 0, y: -s * 0.006)
        ctx.addPath(tile.copy(using: &up) ?? tile)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.55)); ctx.setLineWidth(s * 0.012); ctx.strokePath()
        var lift = CGAffineTransform(translationX: 0, y: s * 0.006)
        ctx.addPath(tile.copy(using: &lift) ?? tile)
        ctx.setStrokeColor(limeRim.copy(alpha: 0.6)!); ctx.setLineWidth(s * 0.012); ctx.strokePath()
    }
    ctx.restoreGState()
    ctx.addPath(tile); ctx.setStrokeColor(limeRim.copy(alpha: 0.5)!); ctx.setLineWidth(max(1, s / 512)); ctx.strokePath()

    // 3. The mark, raised off the tile.
    let center = CGPoint(x: body.midX, y: body.midY)
    let mark = asterisk(center: center, tile: body.width, small: small)
    let depth = small ? 0 : s * 0.016
    var down = CGAffineTransform(translationX: 0, y: -depth)
    let side = mark.copy(using: &down)!

    if !small {
        // Cast shadow onto the tile, then the extruded side.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.03), blur: s * 0.045, color: oklch(0.3, 0.12, 135).copy(alpha: 0.55)!)
        ctx.addPath(side); ctx.setFillColor(inkSide); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(side); ctx.setFillColor(inkSide); ctx.fillPath()
    }

    // Top face: gradient lit from above, with a thin specular line on each arm's upper edge.
    ctx.saveGState()
    ctx.addPath(mark); ctx.clip()
    let markBox = mark.boundingBoxOfPath
    verticalGradient(ctx, in: markBox, top: inkTop, bottom: inkBottom)
    if !small {
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.22))
        ctx.fill(markBox)
        var lower = CGAffineTransform(translationX: 0, y: -s * 0.007)
        ctx.addPath(mark.copy(using: &lower)!); ctx.clip()
        verticalGradient(ctx, in: markBox, top: inkTop, bottom: inkBottom)
    }
    ctx.restoreGState()
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    writePNG(render(size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
writePNG(render(size: 1024), to: resources.appendingPathComponent("AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
