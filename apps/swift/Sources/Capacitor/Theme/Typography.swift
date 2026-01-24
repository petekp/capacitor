import SwiftUI

// MARK: - Semantic Text Styles

/// Typography system providing Dynamic Type support throughout the app.
/// Uses SwiftUI's built-in text styles where possible, with @ScaledMetric for custom sizes.
///
/// ## Design Principles
/// 1. Use semantic names that describe purpose, not pixel sizes
/// 2. Prefer system styles for automatic scaling
/// 3. Use @ScaledMetric for sizes that must scale but don't fit system styles
/// 4. Maintain visual hierarchy at all Dynamic Type sizes
enum AppTypography {
    // MARK: - Page & Section Titles

    /// Large page title (e.g., project detail header)
    /// Maps to: .title (22pt base, scales 20-38)
    static let pageTitle: Font = .title.bold()

    /// Section header within a page
    /// Maps to: .title3 (15pt base, scales 14-25)
    static let sectionTitle: Font = .title3.weight(.semibold)

    // MARK: - Card Content

    /// Primary text in cards (project name, idea title)
    /// Maps to: .headline (13pt semibold base)
    static let cardTitle: Font = .headline

    /// Secondary emphasis in cards
    /// Maps to: .subheadline (11pt base, scales 10-18)
    static let cardSubtitle: Font = .subheadline.weight(.medium)

    // MARK: - Body Text

    /// Primary body text
    /// Maps to: .body (13pt base, scales 12-21)
    static let body: Font = .body

    /// Body text with medium weight
    static let bodyMedium: Font = .body.weight(.medium)

    /// Secondary body text (descriptions, explanations)
    /// Maps to: .callout (12pt base, scales 11-20)
    static let bodySecondary: Font = .callout

    // MARK: - Labels & Captions

    /// Small labels and metadata
    /// Maps to: .footnote (10pt base, scales 9-17)
    static let label: Font = .footnote

    /// Label with medium weight
    static let labelMedium: Font = .footnote.weight(.medium)

    /// Caption text (timestamps, counts)
    /// Maps to: .caption (10pt base, scales 9-17)
    static let caption: Font = .caption

    /// Smallest caption
    /// Maps to: .caption2 (10pt lighter, scales 9-17)
    static let captionSmall: Font = .caption2

    // MARK: - Monospaced (for code, paths, tokens)

    /// Monospaced body text
    static let mono: Font = .body.monospaced()

    /// Monospaced caption
    static let monoCaption: Font = .caption.monospaced()

    // MARK: - Badges & Counts

    /// Badge text (notification counts, status indicators)
    static let badge: Font = .caption2.weight(.bold)
}
