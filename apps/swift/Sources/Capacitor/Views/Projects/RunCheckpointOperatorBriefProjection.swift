import Foundation

struct RunCheckpointOperatorBrief: Equatable {
    let goal: String
    let claim: String
    let changed: [String]
    let evidence: [String]
    let risks: [String]
    let ask: String
}

enum RunCheckpointOperatorBriefProjection {
    static func make(
        run: RuntimeRunState,
        checkpoint: RuntimeCheckpointState,
        manifest: DelegationReviewManifest?,
        manifestLoadError: String?,
    ) -> RunCheckpointOperatorBrief {
        RunCheckpointOperatorBrief(
            goal: goal(for: run),
            claim: claim(for: checkpoint, manifest: manifest),
            changed: changed(for: checkpoint, manifest: manifest),
            evidence: evidence(for: checkpoint, manifest: manifest),
            risks: risks(manifest: manifest, manifestLoadError: manifestLoadError),
            ask: "Approve direction or request changes before the run continues.",
        )
    }

    private static func goal(for run: RuntimeRunState) -> String {
        cleaned(run.ideaTitle)
            ?? cleaned(run.ideaDescription)
            ?? "\(cleaned(run.methodName) ?? "Run") checkpoint"
    }

    private static func claim(
        for checkpoint: RuntimeCheckpointState,
        manifest: DelegationReviewManifest?,
    ) -> String {
        cleaned(manifest?.summary)
            ?? cleaned(checkpoint.summary)
            ?? cleaned(checkpoint.title)
            ?? "Checkpoint is ready for review."
    }

    private static func changed(
        for checkpoint: RuntimeCheckpointState,
        manifest: DelegationReviewManifest?,
    ) -> [String] {
        var values = [String]()
        if let title = cleaned(checkpoint.title) {
            values.append(title)
        }

        if manifest?.swiftChanges == true {
            values.append("Swift changes are included.")
        } else if manifest?.swiftChanges == false {
            values.append("No Swift source changes reported.")
        }

        return unique(values, fallback: "Checkpoint is ready for review.")
    }

    private static func evidence(
        for checkpoint: RuntimeCheckpointState,
        manifest: DelegationReviewManifest?,
    ) -> [String] {
        var values = [String]()

        if let artifacts = manifest?.artifacts {
            values.append(contentsOf: artifacts.compactMap { artifact in
                guard let label = cleaned(artifact.label),
                      let path = cleaned(artifact.path)
                else {
                    return nil
                }
                return "\(label): \(path)"
            })
        }

        values.append(contentsOf: checkpoint.mediaArtifacts.compactMap { artifact in
            guard let label = cleaned(artifact.label),
                  let path = cleaned(artifact.path)
            else {
                return nil
            }
            return "\(label): \(path)"
        })

        values.append(contentsOf: checkpoint.mermaidSources.compactMap { source in
            guard let label = cleaned(source.label) else { return nil }
            return "\(label): Mermaid source attached"
        })

        if values.isEmpty,
           let briefPath = cleaned(checkpoint.briefPath)
        {
            values.append("Checkpoint brief: \(briefPath)")
        }

        return unique(values, fallback: "No evidence artifacts are attached yet.")
    }

    private static func risks(
        manifest _: DelegationReviewManifest?,
        manifestLoadError: String?,
    ) -> [String] {
        if let error = cleaned(manifestLoadError) {
            return ["Manifest unavailable: \(error)"]
        }

        return ["No explicit risks were reported."]
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private static func unique(_ values: [String], fallback: String) -> [String] {
        var seen = Set<String>()
        let cleanedValues = values.compactMap(cleaned).filter { value in
            if seen.contains(value) {
                return false
            }
            seen.insert(value)
            return true
        }
        return cleanedValues.isEmpty ? [fallback] : cleanedValues
    }
}
