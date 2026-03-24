import SwiftUI

/// Displays a captured screenshot with click-to-zoom behavior.
///
/// Loads images asynchronously from a file path and renders them as
/// thumbnails in the review window. Clicking opens a sheet with the
/// full-size image. If a companion `.mmd` file exists (Mermaid source),
/// shows a "Copy Source" button.
struct CaptureImageView: View {
    let filePath: String
    let label: String
    var maxThumbnailHeight: CGFloat = 200

    @State private var image: NSImage?
    @State private var showFullSize = false
    @State private var hasMermaidSource = false
    @State private var copiedSource = false

    private var mermaidSourcePath: String {
        let base = (filePath as NSString).deletingPathExtension
        return base + ".mmd"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(label)
                    .font(AppTypography.caption.weight(.medium))
                    .foregroundColor(.white.opacity(0.7))

                if hasMermaidSource {
                    Button(action: copyMermaidSource) {
                        HStack(spacing: 3) {
                            Image(systemName: copiedSource ? "checkmark" : "doc.on.doc")
                                .font(AppTypography.captionSmall)
                            Text(copiedSource ? "Copied" : "Copy Source")
                                .font(AppTypography.captionSmall.weight(.medium))
                        }
                        .foregroundColor(copiedSource ? .green.opacity(0.7) : .blue.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }

            if let image {
                Button(action: { showFullSize = true }) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: maxThumbnailHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5),
                        )
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showFullSize) {
                    fullSizeView(image: image)
                }
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5),
                    )
                    .frame(height: 120)
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "photo")
                                .font(AppTypography.sectionTitle)
                                .foregroundColor(.white.opacity(0.25))
                            Text("Loading...")
                                .font(AppTypography.caption)
                                .foregroundColor(.white.opacity(0.3))
                        }
                    }
            }
        }
        .task {
            image = await loadImage()
            hasMermaidSource = FileManager.default.fileExists(atPath: mermaidSourcePath)
        }
    }

    private func copyMermaidSource() {
        guard let source = try? String(contentsOfFile: mermaidSourcePath, encoding: .utf8) else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
        copiedSource = true

        _Concurrency.Task { @MainActor in
            try? await _Concurrency.Task.sleep(nanoseconds: 2_000_000_000)
            copiedSource = false
        }
    }

    private func loadImage() async -> NSImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard FileManager.default.fileExists(atPath: filePath) else {
                    continuation.resume(returning: nil)
                    return
                }
                let loaded = NSImage(contentsOfFile: filePath)
                continuation.resume(returning: loaded)
            }
        }
    }

    private func fullSizeView(image: NSImage) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(AppTypography.cardTitle)
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                Button("Close") { showFullSize = false }
                    .keyboardShortcut(.escape)
            }
            .padding(16)

            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height)
            }
            .frame(minWidth: 600, minHeight: 400)
        }
        .background(Color.black.opacity(0.95))
    }
}
