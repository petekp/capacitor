import Foundation
import Combine

enum PlanStatus: String, Codable, CaseIterable {
    case active = "Active"
    case inProgress = "In Progress"
    case implemented = "Implemented"
    case archived = "Archived"

    var icon: String {
        switch self {
        case .active: return "doc.text"
        case .inProgress: return "hammer"
        case .implemented: return "checkmark.circle.fill"
        case .archived: return "archivebox"
        }
    }

    var color: String {
        switch self {
        case .active: return "blue"
        case .inProgress: return "orange"
        case .implemented: return "green"
        case .archived: return "gray"
        }
    }
}

struct Plan: Identifiable {
    let id: String
    let filename: String
    let name: String
    let content: String
    let createdDate: Date?
    let modifiedDate: Date?
    var status: PlanStatus

    var preview: String {
        let lines = content.split(separator: "\n", maxSplits: 3)
        return String(lines.prefix(2).joined(separator: "\n"))
            .trimmingCharacters(in: .whitespaces)
    }

    var wordCount: Int {
        content.split(separator: " ").count
    }
}

struct PlanStatusStorage: Codable {
    var statuses: [String: String]
}

class PlansManager: ObservableObject {
    @Published var plans: [String: [Plan]] = [:]
    @Published var allPlans: [Plan] = []

    private let fileManager = FileManager.default
    private let plansDirectory = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/plans")
    private let statusStoragePath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/hud-plan-statuses.json")
    private var planStatuses: [String: PlanStatus] = [:]

    func loadPlans() {
        loadPlanStatuses()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var allPlans: [Plan] = []
            var projectPlans: [String: [Plan]] = [:]

            do {
                let files = try self.fileManager.contentsOfDirectory(atPath: self.plansDirectory)

                for file in files where file.hasSuffix(".md") {
                    let filePath = (self.plansDirectory as NSString).appendingPathComponent(file)

                    if let content = try? String(contentsOfFile: filePath, encoding: .utf8) {
                        let attributes = try? self.fileManager.attributesOfItem(atPath: filePath)
                        let modifiedDate = attributes?[.modificationDate] as? Date

                        let planName = file.replacingOccurrences(of: ".md", with: "")
                            .split(separator: "-")
                            .dropLast(2)
                            .joined(separator: " ")
                            .capitalized

                        let status = self.planStatuses[file] ?? .active

                        let plan = Plan(
                            id: file,
                            filename: file,
                            name: planName.isEmpty ? file : planName,
                            content: content,
                            createdDate: nil,
                            modifiedDate: modifiedDate,
                            status: status
                        )

                        allPlans.append(plan)
                        projectPlans[file] = [plan]
                    }
                }

                DispatchQueue.main.async {
                    self.allPlans = allPlans.sorted { $0.modifiedDate ?? .distantPast > $1.modifiedDate ?? .distantPast }
                    self.plans = projectPlans
                }
            } catch {
                print("Failed to load plans: \(error)")
            }
        }
    }

    func getPlans(for projectPath: String) -> [Plan] {
        return allPlans.prefix(3).map { $0 }
    }

    func updatePlanStatus(_ planId: String, status: PlanStatus) {
        planStatuses[planId] = status

        if let index = allPlans.firstIndex(where: { $0.id == planId }) {
            allPlans[index].status = status
        }

        savePlanStatuses()
    }

    private func loadPlanStatuses() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statusStoragePath)),
              let storage = try? JSONDecoder().decode(PlanStatusStorage.self, from: data) else {
            return
        }

        for (key, value) in storage.statuses {
            if let status = PlanStatus(rawValue: value) {
                planStatuses[key] = status
            }
        }
    }

    private func savePlanStatuses() {
        let storage = PlanStatusStorage(statuses: planStatuses.mapValues { $0.rawValue })

        if let data = try? JSONEncoder().encode(storage) {
            try? data.write(to: URL(fileURLWithPath: statusStoragePath))
        }
    }
}
