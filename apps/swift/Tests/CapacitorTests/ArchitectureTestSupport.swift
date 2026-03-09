import Foundation
import XCTest

protocol ArchitectureAssertions where Self: XCTestCase {}

extension ArchitectureAssertions {
    func assertFile(
        _ relativePath: String,
        omits forbiddenSnippets: [String],
        file: StaticString = #filePath,
        line: UInt = #line,
    ) throws {
        let source = try loadSourceFile(at: relativePath)
        assertSource(
            source,
            omits: forbiddenSnippets,
            relativePath: relativePath,
            file: file,
            line: line,
        )
    }

    func assertFiles(
        _ relativePaths: [String],
        omits forbiddenSnippets: [String],
        file: StaticString = #filePath,
        line: UInt = #line,
    ) throws {
        for relativePath in relativePaths {
            try assertFile(
                relativePath,
                omits: forbiddenSnippets,
                file: file,
                line: line,
            )
        }
    }

    func assertSource(
        _ source: String,
        omits forbiddenSnippets: [String],
        relativePath: String,
        file: StaticString,
        line: UInt,
    ) {
        for forbiddenSnippet in forbiddenSnippets {
            XCTAssertNil(
                source.range(of: forbiddenSnippet),
                "Unexpected architecture boundary leak in \(relativePath): \(forbiddenSnippet)",
                file: file,
                line: line,
            )
        }
    }

    func assertSwiftFiles(
        under relativeDirectory: String,
        containing snippet: String,
        expectedFiles: [String],
        file: StaticString = #filePath,
        line: UInt = #line,
    ) throws {
        var matchingFiles: [String] = []

        for relativePath in try swiftFiles(under: relativeDirectory) {
            let source = try loadSourceFile(at: relativePath)
            if source.range(of: snippet) != nil {
                matchingFiles.append(relativePath)
            }
        }

        XCTAssertEqual(
            matchingFiles.sorted(),
            expectedFiles.sorted(),
            "Unexpected file set containing \(snippet)",
            file: file,
            line: line,
        )
    }

    func swiftFiles(under relativeDirectory: String) throws -> [String] {
        let baseURL = repositoryRootURL().appendingPathComponent(relativeDirectory)
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: baseURL,
            includingPropertiesForKeys: nil,
        ) else {
            XCTFail("Could not enumerate Swift files under \(relativeDirectory)")
            return []
        }

        var result: [String] = []
        let repositoryRoot = repositoryRootURL()

        while let fileURL = enumerator.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            let relativePath = fileURL.path.replacingOccurrences(
                of: repositoryRoot.path + "/",
                with: "",
            )
            result.append(relativePath)
        }

        return result
    }

    func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }

        var count = 0
        var searchRange = haystack.startIndex ..< haystack.endIndex

        while let matchRange = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = matchRange.upperBound ..< haystack.endIndex
        }

        return count
    }

    func repositoryRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func loadSourceFile(at relativePath: String) throws -> String {
        let fileURL = repositoryRootURL().appendingPathComponent(relativePath)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
