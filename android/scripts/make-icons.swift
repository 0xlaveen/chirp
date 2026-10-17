#!/usr/bin/env swift
// Package the selected artwork into Android's 108 dp adaptive layers and legacy densities.
// Run from any directory: swift android/scripts/make-icons.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let art = root.appendingPathComponent("artwork/chirp-icons")
let res = root.appendingPathComponent("app/src/main/res")
let fm = FileManager.default
let layerSize = 864 // 108 dp at an 8x authoring scale; runtime layers are downsampled to 432 px.
func load(_ name: String) -> CGImage {
    NSBitmapImageRep(data: try! Data(contentsOf: art.appendingPathComponent(name)))!.cgImage!
}
func canvas(_ size: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    draw(context)
    return context.makeImage()!
}
func top(_ x: Double, _ y: Double, _ width: Double, _ height: Double, in size: Int = layerSize) -> CGRect {
    CGRect(x: x, y: Double(size) - y - height, width: width, height: height)
}
func save(_ image: CGImage, _ relative: String) {
    let path = res.appendingPathComponent(relative)
    try! fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: path)
}
func scaled(_ image: CGImage, _ size: Int) -> CGImage {
    canvas(size) { $0.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size)) }
}
func alphaBounds(_ image: CGImage) -> CGRect {
    let rep = NSBitmapImageRep(cgImage: image)
    var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = 0, maxY = 0
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide where rep.colorAt(x: x, y: y)!.alphaComponent > 0.08 {
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}
let pond = load("approved-pond-fullbleed.png")
let background = canvas(layerSize) { ctx in
    ctx.setFillColor(CGColor(red: 0.012, green: 0.07, blue: 0.14, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: layerSize, height: layerSize))
    // Keep the complete approved composition; fit its moon and bird inside the mask.
    // Extend only the navy overscan, without introducing a rounded tile or border.
    let size = Double(layerSize) * 0.72, inset = (Double(layerSize) - size) / 2
    ctx.draw(pond, in: CGRect(x: inset, y: inset, width: size, height: size))
}
let foreground = canvas(layerSize) { _ in } // Explicit operator-approved empty-layer fallback.
let glyph = load("approved-glyph.png")
let trimmedGlyph = glyph.cropping(to: alphaBounds(glyph))!
let monochrome = canvas(layerSize) { ctx in
    let width = 520.0, height = width * Double(trimmedGlyph.height) / Double(trimmedGlyph.width)
    ctx.draw(trimmedGlyph, in: top((864 - width) / 2, (864 - height) / 2, width, height))
}
// The first wave starts to the right of x=770. Crop the approved source, preserving
// the exact bird alpha (including eye/pupil and both feet) instead of redrawing it.
let statusBird = glyph.cropping(to: CGRect(x: 80, y: 275, width: 690, height: 540))!
let notification = canvas(96) { ctx in
    let width = 80.0, height = width * Double(statusBird.height) / Double(statusBird.width)
    ctx.draw(statusBird, in: top(8, (96 - height) / 2, width, height, in: 96))
    ctx.setBlendMode(.sourceIn); ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
}
save(scaled(background, 432), "drawable-nodpi/chirp_launcher_background.png")
save(scaled(foreground, 432), "drawable-nodpi/chirp_launcher_foreground.png")
save(scaled(monochrome, 432), "drawable-nodpi/chirp_launcher_monochrome.png")
save(notification, "drawable-nodpi/ic_chirp_notification.png")
let combined = canvas(layerSize) { ctx in
    ctx.draw(background, in: CGRect(x: 0, y: 0, width: layerSize, height: layerSize))
    ctx.draw(foreground, in: CGRect(x: 0, y: 0, width: layerSize, height: layerSize))
}
let viewport = combined.cropping(to: CGRect(x: 144, y: 144, width: 576, height: 576))!
for (density, size) in [("mdpi",48),("hdpi",72),("xhdpi",96),("xxhdpi",144),("xxxhdpi",192)] {
    // Full-bleed legacy resources too: launcher masks determine the shape.
    save(scaled(pond, size), "mipmap-\(density)/ic_launcher.png")
    let oldRound = res.appendingPathComponent("mipmap-\(density)/ic_launcher_round.png")
    if fm.fileExists(atPath: oldRound.path) { try! fm.removeItem(at: oldRound) }
    let aliases = res.appendingPathComponent("values-\(density)/mipmap_aliases.xml")
    try! fm.createDirectory(at: aliases.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! "<resources><item name=\"ic_launcher_round\" type=\"mipmap\">@mipmap/ic_launcher</item></resources>\n".write(to: aliases, atomically: true, encoding: .utf8)
}
// Keep a large, mask-shaped preview alongside the source artwork for review.
let preview = canvas(576) { ctx in
    ctx.addEllipse(in: CGRect(x: 0, y: 0, width: 576, height: 576)); ctx.clip()
    ctx.draw(viewport, in: CGRect(x: 0, y: 0, width: 576, height: 576))
}
try! NSBitmapImageRep(cgImage: preview).representation(using: .png, properties: [:])!.write(to: art.appendingPathComponent("adaptive-preview.png"))
