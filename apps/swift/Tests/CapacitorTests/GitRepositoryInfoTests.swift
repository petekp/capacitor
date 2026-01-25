@testable import Capacitor
import Foundation
import XCTest

final class GitRepositoryInfoTests: XCTestCase {
    func testResolveReturnsNilAtFilesystemRoot() {
        XCTAssertNil(GitRepositoryInfo.resolve(for: "/"))
    }

    func testResolveFindsRepoRootWhenGitDirectoryExists() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let gitDir = tempDir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)

        let child = tempDir.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let info = GitRepositoryInfo.resolve(for: child.path)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.repoRoot, PathNormalizer.normalize(tempDir.path))
        XCTAssertEqual(info?.relativePath, "child")
    }
}
