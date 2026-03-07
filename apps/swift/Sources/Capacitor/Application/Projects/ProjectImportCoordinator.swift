import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ProjectImportCoordinator {
    typealias SelectDirectories = @MainActor () -> [URL]?
    typealias ConnectSingleProject = (String) -> Void
    typealias ImportProjects = ([URL]) async -> Void
    typealias EnsureProjectListVisible = () -> Void

    private let selectDirectories: SelectDirectories
    private let connectSingleProject: ConnectSingleProject
    private let importProjects: ImportProjects
    private let ensureProjectListVisible: EnsureProjectListVisible

    init(
        selectDirectories: @escaping SelectDirectories = ProjectImportCoordinator.presentDirectoryPicker,
        connectSingleProject: @escaping ConnectSingleProject,
        importProjects: @escaping ImportProjects,
        ensureProjectListVisible: @escaping EnsureProjectListVisible,
    ) {
        self.selectDirectories = selectDirectories
        self.connectSingleProject = connectSingleProject
        self.importProjects = importProjects
        self.ensureProjectListVisible = ensureProjectListVisible
    }

    func connectViaFileBrowser() {
        guard let urls = selectDirectories(), !urls.isEmpty else { return }

        if urls.count > 1 {
            _Concurrency.Task {
                ensureProjectListVisible()
                await importProjects(urls)
            }
            return
        }

        guard let url = urls.first else { return }
        connectSingleProject(url.path)
    }

    func handleFileURLDrop(_ providers: [NSItemProvider]) {
        let loaders: [(@escaping (Data?) -> Void) -> Void] = providers.compactMap { provider in
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
                return nil
            }
            return { completion in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    completion(item as? Data)
                }
            }
        }

        collectDroppedFileURLs(loaders: loaders) { [weak self] urls in
            guard let self, !urls.isEmpty else { return }
            _Concurrency.Task {
                self.ensureProjectListVisible()
                await self.importProjects(urls)
            }
        }
    }

    #if DEBUG
        func collectDroppedFileURLsForTesting(
            loaders: [(@escaping (Data?) -> Void) -> Void],
            completion: @escaping ([URL]) -> Void,
        ) {
            collectDroppedFileURLs(loaders: loaders, completion: completion)
        }
    #endif

    private func collectDroppedFileURLs(
        loaders: [(@escaping (Data?) -> Void) -> Void],
        completion: @escaping ([URL]) -> Void,
    ) {
        guard !loaders.isEmpty else {
            completion([])
            return
        }

        var urls: [URL] = []
        let urlsLock = NSLock()
        let group = DispatchGroup()

        for load in loaders {
            group.enter()
            load { data in
                defer { group.leave() }
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil)
                else {
                    return
                }
                urlsLock.lock()
                urls.append(url)
                urlsLock.unlock()
            }
        }

        group.notify(queue: .main) {
            urlsLock.lock()
            let snapshot = urls
            urlsLock.unlock()
            completion(snapshot)
        }
    }

    private static func presentDirectoryPicker() -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Select a project folder to connect"
        panel.prompt = "Connect"

        guard panel.runModal() == .OK else { return nil }
        return panel.urls
    }
}
