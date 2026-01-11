import SwiftUI

struct PluginRecommendationSection: View {
    let projectPath: String
    @StateObject private var recommender = PluginRecommender()
    @State private var recommendations: [PluginRecommendation] = []

    var body: some View {
        Group {
            if !recommendations.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    DetailSectionLabel(title: "RECOMMENDED PLUGINS")

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(recommendations.prefix(3).enumerated()), id: \.offset) { _, rec in
                            PluginRecommendationRow(recommendation: rec)
                        }

                        if recommendations.count > 3 {
                            Text("+\(recommendations.count - 3) more recommendations")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                }
            }
        }
        .onAppear {
            recommendations = recommender.generateRecommendations(for: projectPath, installedPlugins: [])
        }
    }
}

struct PluginRecommendationRow: View {
    let recommendation: PluginRecommendation

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 12))
                .foregroundColor(.accentColor.opacity(0.7))

            VStack(alignment: .leading, spacing: 2) {
                Text(recommendation.pluginName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))

                Text(recommendation.reason)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.5))
            }

            Spacer()
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(6)
    }
}
