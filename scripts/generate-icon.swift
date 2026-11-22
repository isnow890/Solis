#!/usr/bin/env swift
import Foundation
import AppKit
import CoreGraphics

let rootDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let resourcesDir = rootDir.appendingPathComponent("Resources", isDirectory: true)
let iconsetDir = resourcesDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let icnsPath = resourcesDir.appendingPathComponent("AppIcon.icns")

try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

/// Draws either the back half (top arc in CoreGraphics Y-up) or front half (bottom arc) of an elliptical Saturn ring.
func drawRingArc(
    ctx: CGContext,
    center: CGPoint,
    rx: CGFloat,
    ry: CGFloat,
    angleRad: CGFloat,
    frontHalf: Bool,
    lineWidth: CGFloat,
    strokeColor: CGColor,
    glowColor: CGColor? = nil
) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angleRad)
    // Scale Y so a unit circle becomes an ellipse (rx, ry), keeping uniform stroke width by building points
    let path = CGMutablePath()
    let startAngle: CGFloat = frontHalf ? .pi : 0.0
    let endAngle: CGFloat = frontHalf ? (2.0 * .pi) : .pi
    let steps = 96
    for i in 0...steps {
        let t = startAngle + (endAngle - startAngle) * CGFloat(i) / CGFloat(steps)
        let pt = CGPoint(x: cos(t) * rx, y: sin(t) * ry)
        if i == 0 {
            path.move(to: pt)
        } else {
            path.addLine(to: pt)
        }
    }

    if let glowColor {
        ctx.setShadow(offset: .zero, blur: lineWidth * 1.4, color: glowColor)
    }
    ctx.addPath(path)
    ctx.setStrokeColor(strokeColor)
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

func renderIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // macOS squircle geometry
    let margin = s * 0.0975
    let cardRect = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let cornerRadius = cardRect.width * 0.225
    let cardPath = CGPath(roundedRect: cardRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // Drop shadow under squircle
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.016),
        blur: s * 0.028,
        color: NSColor(calibratedWhite: 0.0, alpha: 0.34).cgColor
    )
    ctx.addPath(cardPath)
    ctx.setFillColor(NSColor(calibratedRed: 0.04, green: 0.08, blue: 0.10, alpha: 1.0).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Clip inside squircle
    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()

    // Deep space dark-teal obsidian gradient
    let bgColors = [
        NSColor(calibratedRed: 0.075, green: 0.135, blue: 0.165, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.035, green: 0.068, blue: 0.092, alpha: 1.0).cgColor
    ] as CFArray
    if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: cardRect.midX, y: cardRect.maxY),
            end: CGPoint(x: cardRect.midX, y: cardRect.minY),
            options: []
        )
    }

    let center = CGPoint(x: cardRect.midX, y: cardRect.midY)

    // Soft mint-cyan atmospheric nebula glow behind the planet
    let auraColors = [
        NSColor(calibratedRed: 0.28, green: 0.94, blue: 0.78, alpha: 0.36).cgColor,
        NSColor(calibratedRed: 0.12, green: 0.72, blue: 0.66, alpha: 0.12).cgColor,
        NSColor(calibratedRed: 0.06, green: 0.40, blue: 0.45, alpha: 0.0).cgColor
    ] as CFArray
    if let auraGrad = CGGradient(colorsSpace: colorSpace, colors: auraColors, locations: [0.0, 0.50, 1.0]) {
        ctx.drawRadialGradient(
            auraGrad,
            startCenter: center,
            startRadius: cardRect.width * 0.08,
            endCenter: center,
            endRadius: cardRect.width * 0.48,
            options: []
        )
    }

    let planetRadius = cardRect.width * 0.23

    // Low-angle sleek asymmetric dual rings (gentle classic Saturn sweep + subtle low cross)
    // Primary hero Saturn ring: gentle classic tilt (-16°), wide & luminous
    let mainRX = cardRect.width * 0.445
    let mainRY = cardRect.width * 0.112
    let mainTilt: CGFloat = -16.0 * .pi / 180.0
    let mainWidth = max(2.2, cardRect.width * 0.038)

    // Secondary accent orbital ring: low-slung asymmetric angle (+28°), tighter & thinner
    let subRX = cardRect.width * 0.365
    let subRY = cardRect.width * 0.088
    let subTilt: CGFloat = 28.0 * .pi / 180.0
    let subWidth = max(1.4, cardRect.width * 0.019)

    let mainRingColor = NSColor(calibratedRed: 0.78, green: 1.00, blue: 0.94, alpha: 0.94).cgColor
    let subRingColor = NSColor(calibratedRed: 0.42, green: 0.94, blue: 0.85, alpha: 0.56).cgColor
    let ringGlow = NSColor(calibratedRed: 0.34, green: 0.98, blue: 0.84, alpha: 0.40).cgColor

    // 1) Draw BOTH full rings behind the planet (seamless outer arcs)
    drawRingArc(ctx: ctx, center: center, rx: subRX, ry: subRY, angleRad: subTilt, frontHalf: false, lineWidth: subWidth, strokeColor: subRingColor)
    drawRingArc(ctx: ctx, center: center, rx: subRX, ry: subRY, angleRad: subTilt, frontHalf: true, lineWidth: subWidth, strokeColor: subRingColor)
    drawRingArc(ctx: ctx, center: center, rx: mainRX, ry: mainRY, angleRad: mainTilt, frontHalf: false, lineWidth: mainWidth, strokeColor: mainRingColor)
    drawRingArc(ctx: ctx, center: center, rx: mainRX, ry: mainRY, angleRad: mainTilt, frontHalf: true, lineWidth: mainWidth, strokeColor: mainRingColor)

    // 2) Mint Planet Sphere
    let planetRect = CGRect(
        x: center.x - planetRadius,
        y: center.y - planetRadius,
        width: planetRadius * 2,
        height: planetRadius * 2
    )
    ctx.saveGState()
    ctx.addEllipse(in: planetRect)
    ctx.clip()

    let planetColors = [
        NSColor(calibratedRed: 0.84, green: 1.00, blue: 0.96, alpha: 1.0).cgColor, // bright icy-mint highlight
        NSColor(calibratedRed: 0.28, green: 0.92, blue: 0.77, alpha: 1.0).cgColor, // vibrant fresh mint
        NSColor(calibratedRed: 0.08, green: 0.56, blue: 0.54, alpha: 1.0).cgColor, // deep teal-mint midtone
        NSColor(calibratedRed: 0.04, green: 0.22, blue: 0.27, alpha: 1.0).cgColor  // cosmic shadow side
    ] as CFArray
    if let planetGrad = CGGradient(colorsSpace: colorSpace, colors: planetColors, locations: [0.0, 0.35, 0.75, 1.0]) {
        ctx.drawRadialGradient(
            planetGrad,
            startCenter: CGPoint(x: center.x - planetRadius * 0.30, y: center.y + planetRadius * 0.32),
            startRadius: 0.0,
            endCenter: center,
            endRadius: planetRadius * 1.18,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    // Subtle atmospheric rim light on the planet
    ctx.addEllipse(in: planetRect.insetBy(dx: planetRadius * 0.02, dy: planetRadius * 0.02))
    ctx.setStrokeColor(NSColor(calibratedRed: 0.80, green: 1.0, blue: 0.96, alpha: 0.34).cgColor)
    ctx.setLineWidth(max(1.0, cardRect.width * 0.011))
    ctx.strokePath()
    ctx.restoreGState()

    // 3) Subtle shadow cast by front rings onto the planet
    ctx.saveGState()
    ctx.addEllipse(in: planetRect)
    ctx.clip()
    let shadowColor = NSColor(calibratedRed: 0.01, green: 0.10, blue: 0.13, alpha: 0.34).cgColor
    drawRingArc(
        ctx: ctx,
        center: CGPoint(x: center.x, y: center.y - cardRect.width * 0.014),
        rx: mainRX,
        ry: mainRY,
        angleRad: mainTilt,
        frontHalf: true,
        lineWidth: mainWidth * 1.12,
        strokeColor: shadowColor
    )
    ctx.restoreGState()

    // 4) Front halves wrapping cleanly in front of the planet (secondary subtle, primary hero bright)
    drawRingArc(ctx: ctx, center: center, rx: subRX, ry: subRY, angleRad: subTilt, frontHalf: true, lineWidth: subWidth, strokeColor: subRingColor)
    drawRingArc(ctx: ctx, center: center, rx: mainRX, ry: mainRY, angleRad: mainTilt, frontHalf: true, lineWidth: mainWidth, strokeColor: mainRingColor, glowColor: ringGlow)

    // 5) Tiny luminous moon dot perched on the steeper orbital ring (upper-right)
    let moonAngle: CGFloat = 0.28 // radians along ellipse
    let mxLocal = cos(moonAngle) * subRX
    let myLocal = sin(moonAngle) * subRY
    let moonCenter = CGPoint(
        x: center.x + mxLocal * cos(subTilt) - myLocal * sin(subTilt),
        y: center.y + mxLocal * sin(subTilt) + myLocal * cos(subTilt)
    )
    let moonR = cardRect.width * 0.036
    let moonRect = CGRect(x: moonCenter.x - moonR, y: moonCenter.y - moonR, width: moonR * 2, height: moonR * 2)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: moonR * 1.6, color: ringGlow)
    ctx.setFillColor(NSColor(calibratedRed: 0.88, green: 1.0, blue: 0.97, alpha: 1.0).cgColor)
    ctx.fillEllipse(in: moonRect)
    ctx.restoreGState()

    // Subtle specular hairline border on squircle
    ctx.addPath(cardPath)
    ctx.setStrokeColor(NSColor(calibratedRed: 0.56, green: 0.98, blue: 0.90, alpha: 0.18).cgColor)
    ctx.setLineWidth(max(1.0, s * 0.011))
    ctx.strokePath()

    ctx.restoreGState()
    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to url: URL, pixelSize: Int) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "IconGen", code: 1)
    }
    rep.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGen", code: 2)
    }
    try png.write(to: url)
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

/// Dedicated crisp small-size icon (16px / 32px) for System Settings & Login Items lists:
/// omits fine sub-ring/moon/aura haze and uses a bolder hero ring so the mint Saturn reads sharply at 16pt.
func renderSmallIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let margin = s * 0.08
    let cardRect = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let cornerRadius = cardRect.width * 0.24
    let cardPath = CGPath(roundedRect: cardRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()

    let bgColors = [
        NSColor(calibratedRed: 0.08, green: 0.14, blue: 0.17, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.03, green: 0.06, blue: 0.09, alpha: 1.0).cgColor
    ] as CFArray
    if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(bgGrad, start: CGPoint(x: cardRect.midX, y: cardRect.maxY), end: CGPoint(x: cardRect.midX, y: cardRect.minY), options: [])
    }

    let center = CGPoint(x: cardRect.midX, y: cardRect.midY)
    let planetR = cardRect.width * 0.25
    let mainRX = cardRect.width * 0.44
    let mainRY = cardRect.width * 0.13
    let tilt: CGFloat = -18.0 * .pi / 180.0
    let ringW = max(1.6, cardRect.width * 0.075)
    let ringColor = NSColor(calibratedRed: 0.82, green: 1.0, blue: 0.95, alpha: 0.98).cgColor

    drawRingArc(ctx: ctx, center: center, rx: mainRX, ry: mainRY, angleRad: tilt, frontHalf: false, lineWidth: ringW, strokeColor: ringColor)

    let planetRect = CGRect(x: center.x - planetR, y: center.y - planetR, width: planetR * 2, height: planetR * 2)
    ctx.saveGState()
    ctx.addEllipse(in: planetRect)
    ctx.clip()
    let planetColors = [
        NSColor(calibratedRed: 0.85, green: 1.0, blue: 0.96, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.24, green: 0.92, blue: 0.76, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.06, green: 0.46, blue: 0.48, alpha: 1.0).cgColor
    ] as CFArray
    if let pGrad = CGGradient(colorsSpace: colorSpace, colors: planetColors, locations: [0.0, 0.45, 1.0]) {
        ctx.drawRadialGradient(pGrad, startCenter: CGPoint(x: center.x - planetR * 0.28, y: center.y + planetR * 0.28), startRadius: 0, endCenter: center, endRadius: planetR * 1.15, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    ctx.restoreGState()

    drawRingArc(ctx: ctx, center: center, rx: mainRX, ry: mainRY, angleRad: tilt, frontHalf: true, lineWidth: ringW, strokeColor: ringColor)

    ctx.restoreGState()
    image.unlockFocus()
    return image
}

let master = renderIcon(size: 1024)
let smallMaster = renderSmallIcon(size: 128)
for (name, px) in specs {
    let source = px <= 32 ? smallMaster : master
    try savePNG(source, to: iconsetDir.appendingPathComponent(name), pixelSize: px)
}

// Optional preview PNG if 2nd arg given
if CommandLine.arguments.count > 2 {
    try savePNG(master, to: URL(fileURLWithPath: CommandLine.arguments[2]), pixelSize: 256)
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsPath.path]
try proc.run()
proc.waitUntilExit()

if proc.terminationStatus != 0 {
    fputs("iconutil failed with status \(proc.terminationStatus)\n", stderr)
    exit(1)
}

try? FileManager.default.removeItem(at: iconsetDir)
print("Generated \(icnsPath.path)")
