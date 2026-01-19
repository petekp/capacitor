import Foundation
import Sparkle

struct SparkleConfiguration {
    let feedURL: String?
    let publicKey: String?

    init(bundle: Bundle = .main) {
        self.feedURL = bundle.infoDictionary?["SUFeedURL"] as? String
        self.publicKey = bundle.infoDictionary?["SUPublicEDKey"] as? String
    }

    init(feedURL: String?, publicKey: String?) {
        self.feedURL = feedURL
        self.publicKey = publicKey
    }

    var isValid: Bool {
        guard let feedURL, !feedURL.isEmpty else { return false }
        guard let publicKey, !publicKey.isEmpty else { return false }
        guard publicKey != "YOUR_PUBLIC_KEY_HERE" else { return false }
        return true
    }
}

final class UpdaterController: ObservableObject {
    private var updaterController: SPUStandardUpdaterController?
    let configuration: SparkleConfiguration

    @Published var canCheckForUpdates = false
    @Published var lastUpdateCheckDate: Date?
    @Published var automaticallyChecksForUpdates: Bool = false {
        didSet {
            updaterController?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    var isAvailable: Bool {
        updaterController != nil
    }

    init(configuration: SparkleConfiguration = SparkleConfiguration()) {
        self.configuration = configuration

        guard configuration.isValid else {
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updaterController = controller

        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates

        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)

        controller.updater.publisher(for: \.lastUpdateCheckDate)
            .assign(to: &$lastUpdateCheckDate)
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
}
