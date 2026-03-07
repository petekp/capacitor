import Foundation

@MainActor
final class LiveProjectListPreferencesGateway: ProjectListPreferencesGateway {
    func loadDormantProjectPaths() -> Set<String> {
        DormantOverrideStore.load()
    }

    func saveDormantProjectPaths(_ paths: Set<String>) {
        DormantOverrideStore.save(paths)
    }

    func loadProjectOrder() -> [String] {
        ProjectOrderStore.load()
    }

    func saveProjectOrder(_ order: [String]) {
        ProjectOrderStore.save(order)
    }

    func migrateProjectOrderIfNeeded() {
        ProjectOrderStore.migrateIfNeeded()
    }
}
