#!/usr/bin/env swift

import AppKit
import Foundation

let cornerRadiusRatio: CGFloat = 0.22544  // Apple's macOS icon corner radius ratio

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
    let outputImage = NSImage(size: size)

    outputImage.lockFocus()

    guard let context = NSGraphicsContext.current?.cgContext else {
        outputImage.unlockFocus()
        return nil
    }

    // Create the superellipse mask path
    let rect = CGRect(origin: .zero, size: size)
    let maskPath = createSuperellipsePath(in: rect)

    // Apply the mask
    context.addPath(maskPath)
    context.clip()

    // Draw the original image
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)

    outputImage.unlockFocus()

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

// Get script directory
let scriptPath = CommandLine.arguments[0]
let scriptDir = (scriptPath as NSString).deletingLastPathComponent
let projectRoot = (scriptDir as NSString).deletingLastPathComponent

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
print("")

// Map input files to their sizes (based on actual pixel dimensions)
let inputMapping: [Int: String] = [
    16: "16.png",           // 16x16
    32: "16@2x.png",        // 32x32 (or use 32.png)
    64: "32@2x.png",        // 64x64
    128: "128.png",         // 128x128
    256: "128@2x.png",      // 256x256 (or use 256.png)
    512: "256@2x.png",      // 512x512 (or use 512.png)
    1024: "512@2x.png"      // 1024x1024
]

for (name, size, _) in iconSizes {
    // Find the best source image (prefer exact match, then larger)
    var sourceFile: String?

    if let exactMatch = inputMapping[size] {
        let path = "\(inputDir)/\(exactMatch)"
        if fileManager.fileExists(atPath: path) {
            sourceFile = path
        }
    }

    // Fall back to the largest available image
    if sourceFile == nil {
        let largestPath = "\(inputDir)/512@2x.png"
        if fileManager.fileExists(atPath: largestPath) {
            sourceFile = largestPath
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
