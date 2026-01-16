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

    /// Subsection or group header
    /// Maps to: .headline (13pt semibold base, scales 12-21)
    static let groupTitle: Font = .headline

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

    /// Monospaced small caption
    static let monoSmall: Font = .caption2.monospaced()

    // MARK: - Tab Bar

    /// Tab bar icon labels
    static let tabLabel: Font = .caption2.weight(.medium)

    // MARK: - Badges & Counts

    /// Badge text (notification counts, status indicators)
    static let badge: Font = .caption2.weight(.bold)
}

// MARK: - Scaled Metrics for Custom Sizes

/// Scaled metrics for sizes that don't map to system text styles.
/// These scale proportionally with Dynamic Type settings.
struct ScaledMetrics {
    // MARK: - Icon Sizes (scale with text)

    /// Small icon (inline with caption text)
    @ScaledMetric(relativeTo: .caption) static var iconSmall: CGFloat = 12

    /// Standard icon (inline with body text)
    @ScaledMetric(relativeTo: .body) static var iconStandard: CGFloat = 16

    /// Medium icon (standalone or header)
    @ScaledMetric(relativeTo: .title3) static var iconMedium: CGFloat = 20

    /// Large icon (card headers, empty states)
    @ScaledMetric(relativeTo: .title) static var iconLarge: CGFloat = 24

    /// Extra large icon (feature icons)
    @ScaledMetric(relativeTo: .largeTitle) static var iconXL: CGFloat = 32

    /// Display icon (empty states, onboarding)
    @ScaledMetric(relativeTo: .largeTitle) static var iconDisplay: CGFloat = 44

    // MARK: - Spacing (scale with text for consistent density)

    /// Tight spacing between related elements
    @ScaledMetric(relativeTo: .caption) static var spacingTight: CGFloat = 4

    /// Standard spacing
    @ScaledMetric(relativeTo: .body) static var spacingStandard: CGFloat = 8

    /// Comfortable spacing between groups
    @ScaledMetric(relativeTo: .body) static var spacingComfortable: CGFloat = 12

    /// Section spacing
    @ScaledMetric(relativeTo: .title3) static var spacingSection: CGFloat = 16

    // MARK: - Touch Targets

    /// Minimum touch target (44pt is Apple's recommendation)
    @ScaledMetric(relativeTo: .body) static var minTouchTarget: CGFloat = 44

    // MARK: - Badge Sizes

    /// Badge minimum width
    @ScaledMetric(relativeTo: .caption2) static var badgeMinWidth: CGFloat = 16

    /// Badge height
    @ScaledMetric(relativeTo: .caption2) static var badgeHeight: CGFloat = 14
}

// MARK: - View Extensions

extension View {
    /// Apply page title typography
    func pageTitle() -> some View {
        font(AppTypography.pageTitle)
    }

    /// Apply section title typography
    func sectionTitle() -> some View {
        font(AppTypography.sectionTitle)
    }

    /// Apply card title typography
    func cardTitle() -> some View {
        font(AppTypography.cardTitle)
    }

    /// Apply body typography
    func bodyText() -> some View {
        font(AppTypography.body)
    }

    /// Apply secondary body typography
    func bodySecondary() -> some View {
        font(AppTypography.bodySecondary)
    }

    /// Apply label typography
    func labelText() -> some View {
        font(AppTypography.label)
    }

    /// Apply caption typography
    func captionText() -> some View {
        font(AppTypography.caption)
    }

    /// Apply monospaced typography
    func monoText() -> some View {
        font(AppTypography.mono)
    }
}

// MARK: - Text Extensions for Convenience

extension Text {
    /// Style as page title
    func pageTitle() -> Text {
        font(AppTypography.pageTitle)
    }

    /// Style as section title
    func sectionTitle() -> Text {
        font(AppTypography.sectionTitle)
    }

    /// Style as card title
    func cardTitle() -> Text {
        font(AppTypography.cardTitle)
    }

    /// Style as body with medium weight
    func bodyMedium() -> Text {
        font(AppTypography.bodyMedium)
    }

    /// Style as label
    func label() -> Text {
        font(AppTypography.label)
    }

    /// Style as label with medium weight
    func labelMedium() -> Text {
        font(AppTypography.labelMedium)
    }

    /// Style as caption
    func caption() -> Text {
        font(AppTypography.caption)
    }

    /// Style as badge text
    func badge() -> Text {
        font(AppTypography.badge)
    }

    /// Style as monospaced
    func mono() -> Text {
        font(AppTypography.mono)
    }

    /// Style as small monospaced
    func monoSmall() -> Text {
        font(AppTypography.monoSmall)
    }
}

// MARK: - Legacy Size Mapping Reference
// This documents the migration from hardcoded sizes to semantic styles:
//
// | Old Size | New Style | Notes |
// |----------|-----------|-------|
// | 8-9pt | .caption2 / .badge | Badges, tiny indicators |
// | 10pt | .footnote / .caption | Meta info, timestamps |
// | 11pt | .subheadline | Secondary labels |
// | 12pt | .callout | Body secondary, labels |
// | 13pt | .body / .headline | Primary content |
// | 14pt | .headline | Card titles, form fields |
// | 15-16pt | .title3 | Section titles |
// | 20-22pt | .title / .title2 | Page titles |
// | 24pt+ | @ScaledMetric icons | Display icons |
