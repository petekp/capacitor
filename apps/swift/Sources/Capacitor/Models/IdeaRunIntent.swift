import Foundation

struct IdeaRunIntent: Equatable {
    let intent: String
    let successCriteria: String?
    let sourceText: String

    static func project(_ idea: Idea) -> IdeaRunIntent {
        let title = cleaned(idea.title)
        let description = cleaned(idea.description)
        let intent = title ?? description?.components(separatedBy: .newlines).first.map(cleaned).flatMap(\.self) ?? ""

        return IdeaRunIntent(
            intent: intent,
            successCriteria: successCriteria(from: description),
            sourceText: [title, description].compactMap(\.self).joined(separator: "\n\n"),
        )
    }

    private static func successCriteria(from description: String?) -> String? {
        guard let description else { return nil }
        for line in description.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let prefix = "Success means:"
            if trimmed.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil {
                return cleaned(String(trimmed.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}
