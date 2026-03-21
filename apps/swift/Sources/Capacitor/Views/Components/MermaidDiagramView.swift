import SwiftUI
import WebKit

/// Renders Mermaid diagram source using WKWebView + mermaid.js CDN.
///
/// Renders only when visible in the view hierarchy (no offscreen pre-rendering).
/// Uses a dark theme to match the review window aesthetic.
struct MermaidDiagramView: NSViewRepresentable {
    let source: String
    let label: String
    var minHeight: CGFloat = 200

    func makeNSView(context _: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator _: ()) {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    func updateNSView(_ webView: WKWebView, context _: Context) {
        let escapedSource = source
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <style>
                body {
                    margin: 0;
                    padding: 16px;
                    background: transparent;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    min-height: 100vh;
                }
                .mermaid {
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                }
                .mermaid svg {
                    max-width: 100%;
                    height: auto;
                }
            </style>
            <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
        </head>
        <body>
            <pre class="mermaid">
        \(escapedSource)
            </pre>
            <script>
                mermaid.initialize({
                    startOnLoad: true,
                    theme: 'dark',
                    themeVariables: {
                        darkMode: true,
                        background: 'transparent',
                        primaryColor: '#3b82f6',
                        primaryTextColor: '#e5e7eb',
                        primaryBorderColor: '#4b5563',
                        lineColor: '#6b7280',
                        secondaryColor: '#1e3a5f',
                        tertiaryColor: '#1f2937'
                    },
                    flowchart: { curve: 'basis' },
                    fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif',
                    fontSize: 14
                });
            </script>
        </body>
        </html>
        """

        webView.loadHTMLString(html, baseURL: nil)
    }
}

/// A labeled wrapper for MermaidDiagramView that fits into the review window.
struct LabeledMermaidView: View {
    let source: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(AppTypography.bodySecondary)
                    .foregroundColor(.blue.opacity(0.6))

                Text(label)
                    .font(AppTypography.caption.weight(.medium))
                    .foregroundColor(.white.opacity(0.65))
            }

            MermaidDiagramView(source: source, label: label)
                .frame(minHeight: 200, maxHeight: 400)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5),
                )
        }
    }
}
