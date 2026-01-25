import SwiftUI

enum RoutingRolloutBadgeCopy {
    static func thresholdSummary(_ rollout: RuntimeRoutingRollout) -> String {
        let minimum = rollout.minComparisonsRequired.map(String.init) ?? "n/a"
        return "\(rollout.comparisons)/\(minimum)"
    }

    static func windowSummary(_ rollout: RuntimeRoutingRollout) -> String {
        let elapsed = rollout.windowElapsedHours.map(String.init) ?? "n/a"
        if let minimum = rollout.minWindowHoursRequired {
            return "\(elapsed)/\(minimum)h"
        }
        return "\(elapsed)/n/a"
    }

    static func gateLabel(_ value: Bool?) -> String {
        guard let value else {
            return "unknown"
        }
        return value ? "yes" : "no"
    }
}

#if DEBUG
    struct RoutingRolloutBadge: View {
        let rollout: RuntimeRoutingRollout

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("ARE rollout gate")
                    .font(AppTypography.captionSmall.weight(.semibold))
                    .foregroundColor(.white.opacity(0.85))

                HStack(spacing: 12) {
                    metric(label: "comparisons", value: RoutingRolloutBadgeCopy.thresholdSummary(rollout))
                    metric(label: "window", value: RoutingRolloutBadgeCopy.windowSummary(rollout))
                }

                HStack(spacing: 6) {
                    gateChip(label: "volume", value: rollout.volumeGateMet)
                    gateChip(label: "window", value: rollout.windowGateMet)
                    gateChip(label: "status", value: rollout.statusGateMet)
                    gateChip(label: "target", value: rollout.targetGateMet)
                }

                HStack(spacing: 6) {
                    gateChip(label: "row default", value: rollout.statusRowDefaultReady)
                    gateChip(label: "launcher default", value: rollout.launcherDefaultReady)
                }

                metric(label: "first", value: rollout.firstComparisonAt ?? "n/a")
                metric(label: "last", value: rollout.lastComparisonAt ?? "n/a")
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.05)),
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5),
            )
        }

        private func metric(label: String, value: String) -> some View {
            HStack(spacing: 6) {
                Text(label)
                    .font(AppTypography.captionSmall)
                    .foregroundColor(.white.opacity(0.45))
                Text(value)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }

        private func gateChip(label: String, value: Bool?) -> some View {
            let statusLabel = RoutingRolloutBadgeCopy.gateLabel(value)
            let accent: Color = switch value {
            case .some(true): .green
            case .some(false): .orange
            case .none: .white
            }

            return Text("\(label): \(statusLabel)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(accent.opacity(0.15)),
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(accent.opacity(0.25), lineWidth: 0.5),
                )
        }
    }
#endif
