import Foundation

@MainActor
@Observable
final class DashboardState {
    private let dashboardLoader: DashboardLoader
    private let ideaCaptureEnabled: () -> Bool
    private let writeError: (String?) -> Void

    private(set) var dashboard: DashboardData?
    private(set) var isLoading = true

    init(
        dashboardLoader: DashboardLoader,
        ideaCaptureEnabled: @escaping () -> Bool,
        writeError: @escaping (String?) -> Void,
    ) {
        self.dashboardLoader = dashboardLoader
        self.ideaCaptureEnabled = ideaCaptureEnabled
        self.writeError = writeError
    }

    func load(hydrateIdeas: Bool = true, showLoadingState: Bool = true) {
        if showLoadingState {
            isLoading = true
        }

        do {
            dashboard = try dashboardLoader.load(hydrateIdeas: hydrateIdeas && ideaCaptureEnabled())
            writeError(nil)
            if showLoadingState {
                isLoading = false
            }
        } catch {
            writeError(error.localizedDescription)
            if showLoadingState {
                isLoading = false
            }
        }
    }

    func setLoading(_ isLoading: Bool) {
        self.isLoading = isLoading
    }
}
