#!/usr/bin/env swift

import AppKit
import Foundation

let cornerRadiusRatio: CGFloat = 0.22544  // Apple's macOS icon corner radius ratio
let defaultContentScale: CGFloat = 0.82     // Matches common Dock icon optical footprint

func resolvedContentScale() -> CGFloat {
    guard let raw = ProcessInfo.processInfo.environment["ICON_CONTENT_SCALE"],
          let value = Double(raw) else {
        return defaultContentScale
    }
    return max(0.6, min(1.0, CGFloat(value)))
}

func createSuperellipsePath(in rect: CGRect) -> CGPath {
    let width = rect.width
    let height = rect.height
    let cornerRadius = min(width, height) * cornerRadiusRatio

    let path = CGMutablePath()

    // Apple's macOS icon shape is a continuous-curvature rounded rectangle (squircle)
    // Using smooth corners similar to Apple's design
    let smoothness: CGFloat = 0.6 // Controls how "squircle-like" vs "rounded rect" the shape is

    let topLeft = CGPoint(x: rect.minX, y: rect.minY)
    let topRight = CGPoint(x: rect.maxX, y: rect.minY)
    let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
    let bottomLeft = CGPoint(x: rect.minX, y: rect.maxY)

    // Start from top-left, going clockwise
    path.move(to: CGPoint(x: topLeft.x + cornerRadius, y: topLeft.y))

    // Top edge
    path.addLine(to: CGPoint(x: topRight.x - cornerRadius, y: topRight.y))

    // Top-right corner
    path.addCurve(
        to: CGPoint(x: topRight.x, y: topRight.y + cornerRadius),
        control1: CGPoint(x: topRight.x - cornerRadius * (1 - smoothness), y: topRight.y),
        control2: CGPoint(x: topRight.x, y: topRight.y + cornerRadius * (1 - smoothness))
    )

    // Right edge
    path.addLine(to: CGPoint(x: bottomRight.x, y: bottomRight.y - cornerRadius))

    // Bottom-right corner
    path.addCurve(
        to: CGPoint(x: bottomRight.x - cornerRadius, y: bottomRight.y),
        control1: CGPoint(x: bottomRight.x, y: bottomRight.y - cornerRadius * (1 - smoothness)),
        control2: CGPoint(x: bottomRight.x - cornerRadius * (1 - smoothness), y: bottomRight.y)
    )

    // Bottom edge
    path.addLine(to: CGPoint(x: bottomLeft.x + cornerRadius, y: bottomLeft.y))

    // Bottom-left corner
    path.addCurve(
        to: CGPoint(x: bottomLeft.x, y: bottomLeft.y - cornerRadius),
        control1: CGPoint(x: bottomLeft.x + cornerRadius * (1 - smoothness), y: bottomLeft.y),
        control2: CGPoint(x: bottomLeft.x, y: bottomLeft.y - cornerRadius * (1 - smoothness))
    )

    // Left edge
    path.addLine(to: CGPoint(x: topLeft.x, y: topLeft.y + cornerRadius))

    // Top-left corner
    path.addCurve(
        to: CGPoint(x: topLeft.x + cornerRadius, y: topLeft.y),
        control1: CGPoint(x: topLeft.x, y: topLeft.y + cornerRadius * (1 - smoothness)),
        control2: CGPoint(x: topLeft.x + cornerRadius * (1 - smoothness), y: topLeft.y)
    )

    path.closeSubpath()
    return path
}

func applyMacOSIconMask(to image: NSImage, size: CGSize) -> NSImage? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width),
        pixelsHigh: Int(size.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return nil
    }

    guard let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else {
        return nil
    }

    let rect = CGRect(origin: .zero, size: size)

    // Render into a transparent target so corner pixels stay alpha=0.
    context.setFillColor(NSColor.clear.cgColor)
    context.fill(rect)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let maskPath = createSuperellipsePath(in: rect)
    context.addPath(maskPath)
    context.clip()

    let contentScale = resolvedContentScale()
    let drawWidth = rect.width * contentScale
    let drawHeight = rect.height * contentScale
    let drawRect = CGRect(
        x: (rect.width - drawWidth) / 2,
        y: (rect.height - drawHeight) / 2,
        width: drawWidth,
        height: drawHeight
    )

    guard let cgImage = image.cgImage(
        forProposedRect: nil,
        context: nil,
        hints: [NSImageRep.HintKey.interpolation: NSImageInterpolation.high]
    ) else {
        return nil
    }

    // Apply a rounded inset enclosure so scaling down stays rounded (not square).
    context.saveGState()
    let insetMaskPath = createSuperellipsePath(in: drawRect)
    context.addPath(insetMaskPath)
    context.clip()
    context.draw(cgImage, in: drawRect)
    context.restoreGState()

    let outputImage = NSImage(size: size)
    outputImage.addRepresentation(rep)
    return outputImage
}

func processIcon(inputPath: String, outputPath: String, targetSize: Int) {
    guard let inputImage = NSImage(contentsOfFile: inputPath) else {
        print("Error: Could not load image from \(inputPath)")
        return
    }

    let size = CGSize(width: targetSize, height: targetSize)

    guard let maskedImage = applyMacOSIconMask(to: inputImage, size: size) else {
        print("Error: Could not apply mask to image")
        return
    }

    // Convert to PNG data
    guard let tiffData = maskedImage.tiffRepresentation,
          let bitmapRep = NSBitmapImageRep(data: tiffData),
          let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
        print("Error: Could not convert image to PNG")
        return
    }

    do {
        try pngData.write(to: URL(fileURLWithPath: outputPath))
        print("✓ Created: \(outputPath)")
    } catch {
        print("Error writing file: \(error)")
    }
}

// Icon sizes for macOS iconset
let iconSizes: [(name: String, size: Int, scale: Int)] = [
    ("icon_16x16", 16, 1),
    ("icon_16x16@2x", 32, 2),
    ("icon_32x32", 32, 1),
    ("icon_32x32@2x", 64, 2),
    ("icon_128x128", 128, 1),
    ("icon_128x128@2x", 256, 2),
    ("icon_256x256", 256, 1),
    ("icon_256x256@2x", 512, 2),
    ("icon_512x512", 512, 1),
    ("icon_512x512@2x", 1024, 2)
]

// Get project root from this script location (works when run via `swift script.swift`).
let scriptURL = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
let projectRoot = scriptURL
    .deletingLastPathComponent() // utils
    .deletingLastPathComponent() // scripts
    .deletingLastPathComponent() // project root
    .path

let inputDir = "\(projectRoot)/assets/Mac"
let outputDir = "\(projectRoot)/assets/AppIcon.iconset"

// Create output directory if needed
let fileManager = FileManager.default
if !fileManager.fileExists(atPath: outputDir) {
    try? fileManager.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
}

print("Applying macOS icon mask to images...")
print("Input: \(inputDir)")
print("Output: \(outputDir)")
print("Content scale: \(String(format: "%.2f", resolvedContentScale()))")
print("")

// Map target size to candidate source files (first match wins).
let inputMapping: [Int: [String]] = [
    16: ["16.png", "MacOS-16.png"],
    32: ["16@2x.png", "32.png", "MacOS-32.png"],
    64: ["32@2x.png", "64.png", "MacOS-64.png"],
    128: ["128.png", "MacOS-128.png"],
    256: ["128@2x.png", "256.png", "MacOS-256.png"],
    512: ["256@2x.png", "512.png", "MacOS-512.png"],
    1024: ["512@2x.png", "1024.png", "MacOS-1024.png"]
]

for (name, size, _) in iconSizes {
    // Find the best source image (prefer exact match names above, then largest available)
    var sourceFile: String?

    if let candidates = inputMapping[size] {
        for candidate in candidates {
            let path = "\(inputDir)/\(candidate)"
            if fileManager.fileExists(atPath: path) {
                sourceFile = path
                break
            }
        }
    }

    // Fall back to the largest available image
    if sourceFile == nil {
        let fallbacks = ["512@2x.png", "1024.png", "MacOS-1024.png"]
        for fallback in fallbacks {
            let largestPath = "\(inputDir)/\(fallback)"
            if fileManager.fileExists(atPath: largestPath) {
                sourceFile = largestPath
                break
            }
        }
    }

    guard let input = sourceFile else {
        print("⚠ Skipping \(name).png - no source image found")
        continue
    }

    let output = "\(outputDir)/\(name).png"
    processIcon(inputPath: input, outputPath: output, targetSize: size)
}

print("")
print("Done! Now run: iconutil -c icns \(outputDir)")
