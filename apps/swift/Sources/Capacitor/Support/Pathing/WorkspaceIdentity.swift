import CryptoKit
import Foundation

enum WorkspaceIdentity {
    static func fromGitInfo(_ info: GitRepositoryInfo) -> String {
        let projectId = info.commonDir ?? info.repoRoot
        let source = "\(projectId)|\(info.relativePath)"
        return hash(source)
    }

    static func fromPath(_ path: String) -> String {
        let normalized = PathNormalizer.normalize(path)
        let source = "\(normalized)|\(normalized)"
        return hash(source)
    }

    private static func hash(_ input: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
