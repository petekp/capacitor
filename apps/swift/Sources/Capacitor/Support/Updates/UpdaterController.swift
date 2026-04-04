import Foundation
import Observation
import Sparkle

struct SparkleConfiguration {
    let feedURL: String?
    let publicKey: String?

    init(bundle: Bundle = .main) {
        feedURL = bundle.infoDictionary?["SUFeedURL"] as? String
        publicKey = bundle.infoDictionary?["SUPublicEDKey"] as? String
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

@Observable
@MainActor
final class UpdaterController {
    @ObservationIgnored private var standardUpdaterController: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckForUpdatesObservation: NSKeyValueObservation?
    @ObservationIgnored private var lastUpdateCheckDateObservation: NSKeyValueObservation?
    @ObservationIgnored private var automaticallyChecksForUpdatesObservation: NSKeyValueObservation?
    let configuration: SparkleConfiguration

    var canCheckForUpdates = false
    var lastUpdateCheckDate: Date?
    var automaticallyChecksForUpdates: Bool = false {
        didSet {
            guard standardUpdaterController?.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            standardUpdaterController?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    var isAvailable: Bool {
        standardUpdaterController != nil
    }

    init(configuration: SparkleConfiguration = SparkleConfiguration()) {
        self.configuration = configuration

        guard configuration.isValid else {
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil,
        )
        standardUpdaterController = controller

        syncState(from: controller.updater)
        installObservers(for: controller.updater)
    }

    func checkForUpdates() {
        standardUpdaterController?.checkForUpdates(nil)
    }

    private func syncState(from updater: SPUUpdater) {
        canCheckForUpdates = updater.canCheckForUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    }

    private func installObservers(for updater: SPUUpdater) {
        canCheckForUpdatesObservation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            _Concurrency.Task { @MainActor [weak self] in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }

        lastUpdateCheckDateObservation = updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] updater, _ in
            _Concurrency.Task { @MainActor [weak self] in
                self?.lastUpdateCheckDate = updater.lastUpdateCheckDate
            }
        }

        automaticallyChecksForUpdatesObservation = updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] updater, _ in
            _Concurrency.Task { @MainActor [weak self] in
                self?.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
            }
        }
    }
}
