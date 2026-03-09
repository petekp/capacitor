@testable import Capacitor
import XCTest

final class ShellSetupInstructionsTests: XCTestCase {
    func testZshSnippetIncludesHookCommand() {
        let snippet = ShellType.zsh.snippet
        XCTAssertTrue(snippet.contains("Capacitor shell integration"))
        XCTAssertTrue(snippet.contains("CAPACITOR_RUNTIME_ENABLED=1"))
        XCTAssertTrue(snippet.contains("capacitor-hook"))
        XCTAssertTrue(snippet.contains("precmd_functions+=(_capacitor_precmd)"))
    }

    func testBashSnippetIncludesPromptCommand() {
        let snippet = ShellType.bash.snippet
        XCTAssertTrue(snippet.contains("Capacitor shell integration"))
        XCTAssertTrue(snippet.contains("CAPACITOR_RUNTIME_ENABLED=1"))
        XCTAssertTrue(snippet.contains("capacitor-hook"))
        XCTAssertTrue(snippet.contains("PROMPT_COMMAND"))
    }

    func testFishSnippetIncludesPostexecHook() {
        let snippet = ShellType.fish.snippet
        XCTAssertTrue(snippet.contains("Capacitor shell integration"))
        XCTAssertTrue(snippet.contains("CAPACITOR_RUNTIME_ENABLED=1"))
        XCTAssertTrue(snippet.contains("capacitor-hook"))
        XCTAssertTrue(snippet.contains("fish_postexec"))
    }

    func testUnsupportedShellSnippetIsPlaceholder() {
        XCTAssertEqual(ShellType.unsupported.snippet, "# Shell integration not available for this shell")
    }
}
