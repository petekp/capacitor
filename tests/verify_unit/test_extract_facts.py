from __future__ import annotations

import pathlib
import importlib.util
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
EXTRACT_FACTS_PATH = ROOT / "scripts/verify/extract-facts.py"
spec = importlib.util.spec_from_file_location("extract_facts_module", EXTRACT_FACTS_PATH)
assert spec is not None and spec.loader is not None
extract_facts = importlib.util.module_from_spec(spec)
sys.path.insert(0, str(ROOT / "scripts/verify"))
spec.loader.exec_module(extract_facts)


class ExtractFactsTests(unittest.TestCase):
    def test_identifier_refs_ignore_comment_only_mentions(self) -> None:
        refs = extract_facts.identifier_refs_for(
            "swift",
            """
struct CommentOnly {
    // fetchRuntimeConfig should not count here
}
""".strip(),
        )

        values = {entry["value"] for entry in refs}
        self.assertNotIn("fetchRuntimeConfig", values)

    def test_process_execs_resolve_swift_helper_bindings(self) -> None:
        content = """
struct BadLauncher {
    func launch() {
        let command = "tmux " + "new-session -A -s capacitor"
        runScript(command)
    }
}
""".strip()

        bindings = extract_facts.static_string_bindings("swift", content)
        process_execs = extract_facts.process_execs_for("swift", content, bindings)

        self.assertEqual([entry["value"] for entry in process_execs], ["tmux new-session -A -s capacitor"])

    def test_process_execs_extract_swift_process_shell_commands(self) -> None:
        content = """
import Foundation

struct Launcher {
    func launch() {
        let script = "tmux " + "switch-client -t capacitor"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
    }
}
""".strip()

        bindings = extract_facts.static_string_bindings("swift", content)
        process_execs = extract_facts.process_execs_for("swift", content, bindings)

        values = [entry["value"] for entry in process_execs]
        self.assertIn("/bin/bash -c tmux switch-client -t capacitor", values)
        self.assertIn("tmux switch-client -t capacitor", values)

    def test_doc_claims_parse_marker_ids_and_owner_scopes(self) -> None:
        claims = extract_facts.doc_claims_for(
            """
VERIFIER_CLAIM(runtime_boundary_service): owner_scope=core/hud-hook/src/serve.rs; Runtime boundary stays local.
""".strip()
        )

        self.assertEqual(len(claims), 1)
        self.assertEqual(claims[0]["id"], "runtime_boundary_service")
        self.assertEqual(claims[0]["owner_scopes"], ["core/hud-hook/src/serve.rs"])


if __name__ == "__main__":
    unittest.main()
