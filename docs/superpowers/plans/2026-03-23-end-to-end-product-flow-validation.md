# End-to-End Product Flow Validation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Validate the full idea→delegation→orchestration→method→checkpoint product loop by wiring real adapters to the method-runner CLI, building an end-to-end integration test harness, and verifying checkpoint presentation quality through the run kernel.

**Architecture:** The system has two checkpoint mechanisms that converge on the same user experience:
1. **Method runner gates** (Rust `executor.rs`) — approval/handoff/outputs gates evaluated via `InteractiveIO` trait during method YAML execution
2. **Run kernel checkpoints** (Rust `run_reducer.rs` + Swift `DelegationReviewWindow`) — `EmitCheckpoint`/`SubmitDecision` mutations that pause runs and present visual artifacts in the app UI

Today these are tested in isolation (method runner with FakeInteractiveIO; run kernel with unit reducer tests). This plan validates the product flow by: (A) wiring real adapters to the CLI, (B) creating a realistic multi-phase method with checkpoints, (C) building a checkpoint manifest generator so method runner gates produce the rich artifacts the Swift UI expects, and (D) integration-testing the full chain.

**Tech Stack:** Rust (method_runner, run_kernel), shell (fake-codex.sh, compose-prompt.sh), YAML (method definitions), JSON (checkpoint manifests, review artifacts)

---

## Scope: What This Plan Covers

### In scope
1. Wire real adapters (ShellPromptBuilder + CodexWorkerDispatcher) to the method-runner binary via a `--real` flag
2. Create a comprehensive "idea-to-ship" method YAML that exercises every gate type and the full checkpoint UX
3. Build a `FileInteractiveIO` adapter that reads decisions from JSON files (bridging method runner gates to file-based checkpoint review)
4. Create a checkpoint manifest generator that method runner gates can use to produce `DelegationReviewManifest`-compatible JSON
5. Integration test: run the full method end-to-end with fake-codex.sh, verify all checkpoint artifacts are produced, and validate the manifest format matches what the Swift UI expects
6. Validate the run kernel checkpoint emission path with a realistic scenario test

### Out of scope (future work)
- Swift-backed live `InteractiveIO` (requires bidirectional IPC between method runner and app)
- LLM-based predictive responses at checkpoints
- Idea→method selection UI in Swift

---

## Task 1: Wire real adapters to method-runner binary

**Files:**
- Modify: `core/capacitor-core/src/bin/method_runner.rs`
- Test: `scripts/test/test-method-runner-cli.sh` (new)

This is the critical first step — the binary currently hardcodes `FakePromptBuilder`, `FakeWorkerDispatcher`, and `FakeInteractiveIO::new("approved")`. We add a `--real` flag that swaps in the real subprocess adapters, and a `--approve`/`--reject`/`--response-dir` flag for non-interactive checkpoint control.

- [ ] **Step 1: Extend ParsedOptions, InteractiveMode, and Command structs**

Add new types and extend all three structs:

```rust
use std::time::Duration;

use capacitor_core::method_runner::adapter_config::AdapterConfig;
use capacitor_core::method_runner::adapters::{
    FakeInteractiveIO, FakePromptBuilder, FakeWorkerDispatcher, FileInteractiveIO,
};
use capacitor_core::method_runner::prompt_builder_adapter::ShellPromptBuilder;
use capacitor_core::method_runner::worker_dispatch_adapter::CodexWorkerDispatcher;

#[derive(Debug, Default)]
enum InteractiveMode {
    #[default]
    AutoApprove,
    AutoReject,
    ResponseDir(PathBuf),
}

#[derive(Debug, Default)]
struct ParsedOptions {
    definition: Option<PathBuf>,
    root: Option<PathBuf>,
    real_adapters: bool,
    interactive_mode: InteractiveMode,
}

#[derive(Debug)]
struct Command {
    kind: CommandKind,
    definition: Option<PathBuf>,
    root: PathBuf,
    real_adapters: bool,
    interactive_mode: InteractiveMode,
}
```

In `parse_cli`, transfer the new fields from `ParsedOptions` to `Command`:

```rust
Ok(Command {
    kind,
    definition: options.definition,
    root,
    real_adapters: options.real_adapters,
    interactive_mode: options.interactive_mode,
})
```

In `parse_options`, add match arms:

```rust
"--real" => {
    parsed.real_adapters = true;
}
"--approve" => {
    parsed.interactive_mode = InteractiveMode::AutoApprove;
}
"--reject" => {
    parsed.interactive_mode = InteractiveMode::AutoReject;
}
"--response-dir" => {
    let value = next_path_value(&mut args, "--response-dir")?;
    parsed.interactive_mode = InteractiveMode::ResponseDir(value);
}
```

- [ ] **Step 2: Add helper functions for locating binaries and building IO adapters**

```rust
/// Find compose-prompt.sh: check COMPOSE_SCRIPT_PATH env, then relative to cargo manifest.
fn find_compose_script() -> Result<PathBuf, String> {
    if let Ok(path) = env::var("COMPOSE_SCRIPT_PATH") {
        let p = PathBuf::from(path);
        if p.exists() {
            return Ok(p);
        }
    }
    // Relative to project root: scripts/relay/compose-prompt.sh
    let candidates = [
        PathBuf::from("scripts/relay/compose-prompt.sh"),
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../scripts/relay/compose-prompt.sh"),
    ];
    for c in &candidates {
        if let Ok(canonical) = c.canonicalize() {
            return Ok(canonical);
        }
    }
    Err("cannot find compose-prompt.sh (set COMPOSE_SCRIPT_PATH)".into())
}

/// Find codex binary: check CODEX_PATH env, then `which codex`.
fn find_codex_binary() -> Result<PathBuf, String> {
    if let Ok(path) = env::var("CODEX_PATH") {
        let p = PathBuf::from(path);
        if p.exists() {
            return Ok(p);
        }
    }
    // Try `which codex`
    let output = std::process::Command::new("which")
        .arg("codex")
        .output()
        .map_err(|e| format!("failed to run `which codex`: {e}"))?;
    if output.status.success() {
        let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !path.is_empty() {
            return Ok(PathBuf::from(path));
        }
    }
    Err("cannot find codex binary (set CODEX_PATH)".into())
}

fn make_interactive_io(mode: &InteractiveMode) -> Box<dyn capacitor_core::method_runner::adapters::InteractiveIO> {
    match mode {
        InteractiveMode::AutoApprove => Box::new(FakeInteractiveIO::new("approved")),
        InteractiveMode::AutoReject => Box::new(FakeInteractiveIO::new("rejected")),
        InteractiveMode::ResponseDir(dir) => Box::new(FileInteractiveIO::new(dir.clone())),
    }
}
```

- [ ] **Step 3: Wire real adapters in the `Run` command when `--real` is set**

Replace the `CommandKind::Run` match arm:

```rust
CommandKind::Run => {
    let source = DefinitionSource {
        definition_path: command.definition.expect("--definition required"),
        execution_root: command.root.clone(),
    };
    let interactive_io = make_interactive_io(&command.interactive_mode);
    if command.real_adapters {
        let script = find_compose_script().map_err(|e| { eprintln!("error: {e}"); })?;
        let codex = find_codex_binary().map_err(|e| { eprintln!("error: {e}"); })?;
        let config = AdapterConfig::new(
            script, codex, command.root.clone(),
            Duration::from_secs(300), Duration::from_secs(5),
        ).map_err(|e| { eprintln!("adapter config error: {e}"); })?;
        let prompt_builder = ShellPromptBuilder::new(config.clone());
        let dispatcher = CodexWorkerDispatcher::new(config);
        match execute_run(&source, &prompt_builder, &dispatcher, interactive_io.as_ref()) {
            Ok(state) => { /* print summary */ ExitCode::SUCCESS }
            Err(e) => { eprintln!("error: {e}"); ExitCode::FAILURE }
        }
    } else {
        let prompt_builder = FakePromptBuilder;
        let dispatcher = FakeWorkerDispatcher;
        match execute_run(&source, &prompt_builder, &dispatcher, interactive_io.as_ref()) {
            Ok(state) => { /* print summary */ ExitCode::SUCCESS }
            Err(e) => { eprintln!("error: {e}"); ExitCode::FAILURE }
        }
    }
}
```

Note: The `map_err` closures print and return unit — the `?` on `Result<_, ()>` maps to `ExitCode::FAILURE` when you restructure the outer match to handle `Result<ExitCode, ()>`. Alternatively, use `unwrap_or_else` pattern.

- [ ] **Step 3: Run `cargo fmt && cargo clippy -- -D warnings && cargo test -p capacitor-core`**

Expected: all pass (no behavioral change to existing tests)

- [ ] **Step 4: Write a smoke test script**

Create `scripts/test/test-method-runner-cli.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Test 1: --help still works
cargo run -p capacitor-core --bin method-runner -- --help 2>&1 | grep -q "Usage:"

# Test 2: normalize with fixture
TMP=$(mktemp -d)
cargo run -p capacitor-core --bin method-runner -- normalize \
  --definition methods/fixtures/minimal-dispatch.yaml \
  --root "$TMP/run1"
test -f "$TMP/run1/.method/definition-snapshot.yaml"

# Test 3: run with fake adapters (default, no --real)
cargo run -p capacitor-core --bin method-runner -- run \
  --definition methods/fixtures/minimal-dispatch.yaml \
  --root "$TMP/run2"
test -f "$TMP/run2/.method/events.ndjson"

echo "All CLI smoke tests passed"
```

- [ ] **Step 5: Run the smoke test**

Run: `bash scripts/test/test-method-runner-cli.sh`
Expected: "All CLI smoke tests passed"

- [ ] **Step 6: Commit**

```bash
git add core/capacitor-core/src/bin/method_runner.rs scripts/test/test-method-runner-cli.sh
git commit -m "feat(method-runner): wire real adapters via --real flag and add interactive mode flags"
```

---

## Task 2: Create FileInteractiveIO adapter

**Files:**
- Modify: `core/capacitor-core/src/method_runner/adapters.rs`
- Test: `core/capacitor-core/tests/method_runner/adapter_seam.rs` (extend)

The shipped v1 method-runner surface supports blanket `--approve` / `--reject` decisions plus `--response-dir` for staged JSON responses. For end-to-end testing, we need the directory-backed adapter path so we can test multi-gate methods non-interactively with different decisions per gate.

- [ ] **Step 1: Write the failing test**

In `adapter_seam.rs`, add:

```rust
#[test]
fn file_interactive_io_reads_gate_responses() {
    let tmp = tempfile::tempdir().unwrap();
    let response_dir = tmp.path().join("responses");
    std::fs::create_dir_all(&response_dir).unwrap();

    // Stage a response file for gate "build-gate"
    std::fs::write(
        response_dir.join("build-gate.json"),
        r#"{"action": "approved", "note": "Looks good"}"#,
    ).unwrap();

    let io = FileInteractiveIO::new(response_dir);

    // When prompted with gate id "build-gate", should return "approved"
    io.emit_prompt(&InteractivePrompt {
        message: "Gate 'build-gate': Do you approve this phase?".into(),
    });
    let response = io.capture_response();
    assert_eq!(response.body.trim(), "approved");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p capacitor-core file_interactive_io_reads -- --nocapture`
Expected: FAIL — `FileInteractiveIO` not defined

- [ ] **Step 3: Implement FileInteractiveIO**

In `adapters.rs`, add:

```rust
/// File-backed interactive IO for testing multi-gate methods.
///
/// Handles TWO prompt formats:
/// 1. Gate prompts: `"Gate '<gate_id>': ..."` → looks up `{response_dir}/{gate_id}.json`
/// 2. Interactive step prompts: raw prompt text → looks up `{response_dir}/{step_id}.json`
///    where step_id is extracted by hashing the prompt (or a `_default.json` fallback)
///
/// Response JSON format: `{"action": "approved", "note": "optional note"}`
/// Falls back to "approved" if no matching file exists.
pub struct FileInteractiveIO {
    response_dir: PathBuf,
    current_prompt_key: std::cell::RefCell<Option<String>>,
}

impl FileInteractiveIO {
    pub fn new(response_dir: PathBuf) -> Self {
        Self {
            response_dir,
            current_prompt_key: RefCell::new(None),
        }
    }

    /// Extract a lookup key from a prompt message.
    /// Gate prompts: "Gate 'build-gate': ..." → "build-gate"
    /// Interactive step prompts: try to find a step-id-like slug, else use "_default"
    fn extract_key(message: &str) -> String {
        // Try gate format first: "Gate '<id>':"
        if let Some(after) = message.strip_prefix("Gate '") {
            if let Some(id) = after.split("':").next() {
                return id.to_string();
            }
        }
        // For interactive step prompts, use a normalized slug of the first
        // 40 chars as the key, or "_default" if empty
        let slug: String = message.chars()
            .take(40)
            .map(|c| if c.is_alphanumeric() { c.to_ascii_lowercase() } else { '-' })
            .collect();
        let slug = slug.trim_matches('-').to_string();
        if slug.is_empty() { "_default".to_string() } else { slug }
    }
}

impl InteractiveIO for FileInteractiveIO {
    fn emit_prompt(&self, prompt: &InteractivePrompt) {
        *self.current_prompt_key.borrow_mut() = Some(Self::extract_key(&prompt.message));
    }

    fn capture_response(&self) -> InteractiveResponse {
        let key = self.current_prompt_key.borrow();
        let body = if let Some(ref k) = *key {
            let path = self.response_dir.join(format!("{}.json", k));
            let fallback = self.response_dir.join("_default.json");
            let target = if path.exists() { path } else { fallback };
            if target.exists() {
                let content = std::fs::read_to_string(&target).unwrap_or_default();
                serde_json::from_str::<serde_json::Value>(&content)
                    .ok()
                    .and_then(|v| v["action"].as_str().map(String::from))
                    .unwrap_or_else(|| "approved".into())
            } else {
                "approved".into()
            }
        } else {
            "approved".into()
        };
        InteractiveResponse { body }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test -p capacitor-core file_interactive_io_reads -- --nocapture`
Expected: PASS

- [ ] **Step 5: Add test for missing file fallback**

```rust
#[test]
fn file_interactive_io_falls_back_to_approved() {
    let tmp = tempfile::tempdir().unwrap();
    let io = FileInteractiveIO::new(tmp.path().to_path_buf());

    io.emit_prompt(&InteractivePrompt {
        message: "Gate 'unknown-gate': Do you approve?".into(),
    });
    let response = io.capture_response();
    assert_eq!(response.body.trim(), "approved");
}
```

- [ ] **Step 6: Run full test suite**

Run: `cargo test -p capacitor-core`
Expected: 712+ tests pass (710 existing + 2 new)

- [ ] **Step 7: Commit**

```bash
git add core/capacitor-core/src/method_runner/adapters.rs core/capacitor-core/tests/method_runner/adapter_seam.rs
git commit -m "feat(adapters): add FileInteractiveIO for testing multi-gate methods with pre-staged decisions"
```

---

## Task 3: Create comprehensive "idea-to-ship" method YAML

**Files:**
- Create: `methods/fixtures/idea-to-ship.yaml`

This method exercises the full product loop: shape → build → review → ship. It includes every gate type, multi-worker steps, interactive checkpoints, and output binding.

- [ ] **Step 1: Write the method YAML**

Create `methods/fixtures/idea-to-ship.yaml`:

```yaml
schema_version: "1"
method:
  id: idea-to-ship
  version: "2026-03-23"
  title: Idea to Ship
  description: >
    Full product loop: shape the idea, build the implementation,
    review at a checkpoint, then ship. Exercises all gate types
    and the complete checkpoint UX.
  defaults:
    max_attempts: 2
    completion_policy: all_complete
    skills:
      - base-skill
  outputs:
    implementation:
      from: build.implement.implementation
      required: true
    review_decision:
      from: review.checkpoint.review_decision
      required: true
  phases:
    # Phase 1: Shape — proposal gate (approval)
    - id: shape
      title: Shape
      execution: serial
      gate:
        id: shape-gate
        type: approval
      steps:
        - id: analyze
          title: Analyze Requirements
          action: dispatch
          outputs:
            analysis:
              path: artifacts/analysis.md
              type: markdown
          dispatch:
            instructions: >
              Analyze the idea and produce a requirements analysis.
              Output a structured markdown document with sections:
              Problem, Approach, Risks, Success Criteria.

    # Phase 2: Build — handoff verdict gate
    - id: build
      title: Build
      execution: serial
      skills:
        - build-skill
      gate:
        id: build-gate
        type: handoff_verdict
      steps:
        - id: implement
          title: Implement
          action: dispatch
          template: implement
          outputs:
            implementation:
              path: artifacts/implementation.md
              type: markdown
          dispatch:
            instructions: >
              Implement the feature based on the shaped requirements.
            workers:
              - id: primary
                title: Primary Worker
                instructions: >
                  Build the core feature.
                skills:
                  - implement-skill

    # Phase 3: Review — interactive approval checkpoint
    - id: review
      title: Review
      execution: serial
      gate:
        id: review-gate
        type: approval
      steps:
        - id: checkpoint
          title: Review Checkpoint
          action: interactive
          outputs:
            review_decision:
              path: artifacts/review-decision.md
              type: markdown
          interactive:
            prompt: >
              Review the implementation. Check that all acceptance
              criteria are met, tests pass, and code quality is good.
              Approve to proceed to ship, or reject with notes.
            response_type: approval
            output: review_decision

    # Phase 4: Ship — completion claim gate
    - id: ship
      title: Ship
      execution: serial
      gate:
        id: ship-gate
        type: completion_claim
      steps:
        - id: release
          title: Release
          action: dispatch
          outputs:
            release_notes:
              path: artifacts/release-notes.md
              type: markdown
          dispatch:
            instructions: >
              Create release notes and tag the release.
```

- [ ] **Step 2: Validate the fixture normalizes**

Run: `cargo run -p capacitor-core --bin method-runner -- normalize --definition methods/fixtures/idea-to-ship.yaml --root /tmp/idea-to-ship-test`
Expected: "normalize complete" with no errors

- [ ] **Step 3: Run with fake adapters to verify full flow**

Run: `cargo run -p capacitor-core --bin method-runner -- run --definition methods/fixtures/idea-to-ship.yaml --root /tmp/idea-to-ship-run`
Expected: "run complete" — all 4 phases execute with auto-approved gates

- [ ] **Step 4: Commit**

```bash
git add methods/fixtures/idea-to-ship.yaml
git commit -m "feat(fixtures): add idea-to-ship method exercising all gate types and checkpoint UX"
```

---

## Task 4: Build checkpoint manifest generator

**Files:**
- Create: `core/capacitor-core/src/method_runner/checkpoint_manifest.rs`
- Modify: `core/capacitor-core/src/method_runner/mod.rs`
- Test: `core/capacitor-core/tests/method_runner/checkpoint_manifest.rs` (new)
- Modify: `core/capacitor-core/tests/method_runner/mod.rs`

When a method runner gate pauses for approval, it should write a `review-manifest.json` that the Swift UI (`DelegationReviewManifest`) can read. This bridges the two checkpoint systems.

- [ ] **Step 1: Write the failing test**

Create `core/capacitor-core/tests/method_runner/checkpoint_manifest.rs`:

```rust
//! Tests for checkpoint manifest generation.

use capacitor_core::method_runner::checkpoint_manifest::CheckpointManifest;

#[test]
fn manifest_serializes_to_review_format() {
    let manifest = CheckpointManifest::new("build-gate")
        .summary("Build phase complete. 3 files changed, all tests pass.")
        .artifact("Implementation diff", "artifacts/implementation.md", "text")
        .artifact("Architecture diagram", "artifacts/arch.png", "screenshot")
        .decision_hint_approve("Ship it", "All acceptance criteria met")
        .decision_hint_request_changes("Needs work", "See review notes");

    let json = manifest.to_json_pretty().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    assert_eq!(parsed["version"], 1);
    assert_eq!(parsed["milestone_id"], "build-gate");
    assert_eq!(parsed["artifacts"].as_array().unwrap().len(), 2);
    assert!(parsed["decisions"]["approve"]["label"].is_string());
    assert!(parsed["decisions"]["request_changes"]["label"].is_string());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p capacitor-core manifest_serializes -- --nocapture`
Expected: FAIL — module not found

- [ ] **Step 3: Implement the manifest generator**

Create `core/capacitor-core/src/method_runner/checkpoint_manifest.rs`:

```rust
//! Checkpoint manifest generator.
//!
//! Produces JSON manifests compatible with the Swift UI's
//! `DelegationReviewManifest` format, bridging method runner
//! gates to the app's visual checkpoint experience.

use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct CheckpointManifest {
    pub version: u32,
    pub milestone_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    pub artifacts: Vec<ManifestArtifact>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub decisions: Option<ManifestDecisions>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub swift_changes: Option<bool>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ManifestArtifact {
    pub label: String,
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub artifact_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub width: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub height: Option<u32>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ManifestDecisions {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub approve: Option<ManifestDecisionHint>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_changes: Option<ManifestDecisionHint>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ManifestDecisionHint {
    pub label: String,
    pub description: String,
}

impl CheckpointManifest {
    pub fn new(milestone_id: &str) -> Self {
        Self {
            version: 1,
            milestone_id: milestone_id.to_string(),
            summary: None,
            artifacts: Vec::new(),
            decisions: None,
            swift_changes: None,
        }
    }

    pub fn summary(mut self, summary: &str) -> Self {
        self.summary = Some(summary.to_string());
        self
    }

    pub fn artifact(mut self, label: &str, path: &str, artifact_type: &str) -> Self {
        self.artifacts.push(ManifestArtifact {
            label: label.to_string(),
            path: path.to_string(),
            artifact_type: Some(artifact_type.to_string()),
            width: None,
            height: None,
        });
        self
    }

    pub fn decision_hint_approve(mut self, label: &str, description: &str) -> Self {
        let hints = self.decisions.get_or_insert(ManifestDecisions {
            approve: None,
            request_changes: None,
        });
        hints.approve = Some(ManifestDecisionHint {
            label: label.to_string(),
            description: description.to_string(),
        });
        self
    }

    pub fn decision_hint_request_changes(mut self, label: &str, description: &str) -> Self {
        let hints = self.decisions.get_or_insert(ManifestDecisions {
            approve: None,
            request_changes: None,
        });
        hints.request_changes = Some(ManifestDecisionHint {
            label: label.to_string(),
            description: description.to_string(),
        });
        self
    }

    pub fn to_json_pretty(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string_pretty(self)
    }

    /// Write the manifest to `{relay_root}/adapter/review-manifest.json`.
    pub fn write_to(&self, relay_root: &std::path::Path) -> std::io::Result<()> {
        let adapter_dir = relay_root.join("adapter");
        std::fs::create_dir_all(&adapter_dir)?;
        let json = self.to_json_pretty().map_err(|e| {
            std::io::Error::new(std::io::ErrorKind::Other, e.to_string())
        })?;
        std::fs::write(adapter_dir.join("review-manifest.json"), json)
    }
}
```

- [ ] **Step 4: Register module in mod.rs**

Add `pub mod checkpoint_manifest;` to `core/capacitor-core/src/method_runner/mod.rs`.

- [ ] **Step 5: Register test module**

Add `mod checkpoint_manifest;` to `core/capacitor-core/tests/method_runner/mod.rs`.

- [ ] **Step 6: Run test to verify it passes**

Run: `cargo test -p capacitor-core manifest_serializes -- --nocapture`
Expected: PASS

- [ ] **Step 7: Add test for write_to**

```rust
#[test]
fn manifest_writes_to_relay_root() {
    let tmp = tempfile::tempdir().unwrap();
    let relay_root = tmp.path().join("relay");

    let manifest = CheckpointManifest::new("test-gate")
        .summary("Test checkpoint");
    manifest.write_to(&relay_root).unwrap();

    let path = relay_root.join("adapter/review-manifest.json");
    assert!(path.exists(), "manifest file must be written");

    let content: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(content["milestone_id"], "test-gate");
}
```

- [ ] **Step 8: Run full suite**

Run: `cargo fmt && cargo clippy -- -D warnings && cargo test -p capacitor-core`
Expected: 714+ tests pass

- [ ] **Step 9: Commit**

```bash
git add core/capacitor-core/src/method_runner/checkpoint_manifest.rs \
        core/capacitor-core/src/method_runner/mod.rs \
        core/capacitor-core/tests/method_runner/checkpoint_manifest.rs \
        core/capacitor-core/tests/method_runner/mod.rs
git commit -m "feat(checkpoint): add manifest generator bridging method runner gates to Swift review UI"
```

---

## Task 5: End-to-end integration test with fake-codex

**Files:**
- Create: `scripts/test/test-idea-to-ship-e2e.sh`

This is the capstone: run the full idea-to-ship method with real adapters (ShellPromptBuilder + CodexWorkerDispatcher using fake-codex.sh), pre-staged gate responses, and verify all checkpoint artifacts.

- [ ] **Step 1: Write the end-to-end test script**

Create `scripts/test/test-idea-to-ship-e2e.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "=== End-to-End: Idea-to-Ship Flow ==="

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

RELAY_ROOT="$TMP/run"
RESPONSE_DIR="$TMP/responses"
CAPTURE_DIR="$TMP/capture"

mkdir -p "$RESPONSE_DIR" "$CAPTURE_DIR"

# Stage gate responses:
# shape-gate: approved (proceed to build)
# build-gate: auto-pass (handoff_verdict, not interactive)
# review-gate: approved (proceed to ship)
# ship-gate: auto-pass (completion_claim, not interactive)
echo '{"action": "approved", "note": "Shape looks good"}' > "$RESPONSE_DIR/shape-gate.json"
echo '{"action": "approved", "note": "Implementation approved"}' > "$RESPONSE_DIR/review-gate.json"

# Run with real adapters + fake-codex + FileInteractiveIO
echo "--- Running idea-to-ship method ---"
CODEX_PATH="$(cd "$(dirname "$0")/../.." && pwd)/scripts/test/fake-codex.sh" \
FAKE_CODEX_CAPTURE_DIR="$CAPTURE_DIR" \
FAKE_CODEX_EXIT_CODE=0 \
FAKE_CODEX_SLEEP_SECS=0 \
FAKE_CODEX_WRITE_HANDOFF=1 \
FAKE_CODEX_WRITE_LAST_MESSAGE=1 \
  cargo run -p capacitor-core --bin method-runner -- run \
    --definition methods/fixtures/idea-to-ship.yaml \
    --root "$RELAY_ROOT" \
    --real \
    --response-dir "$RESPONSE_DIR"

echo "--- Verifying artifacts ---"

# 1. Events file exists
test -f "$RELAY_ROOT/.method/events.ndjson" || { echo "FAIL: events.ndjson missing"; exit 1; }

# 2. State file exists
test -f "$RELAY_ROOT/.method/state.json" || { echo "FAIL: state.json missing"; exit 1; }

# 3. Check state shows completed
STATUS=$(cat "$RELAY_ROOT/.method/state.json" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])")
test "$STATUS" = "completed" || { echo "FAIL: expected completed, got $STATUS"; exit 1; }

# 4. At least one preflight.json exists somewhere under .method/
PREFLIGHT_COUNT=$(find "$RELAY_ROOT/.method" -name "preflight.json" 2>/dev/null | wc -l | tr -d ' ')
test "$PREFLIGHT_COUNT" -gt 0 || { echo "FAIL: no preflight.json found anywhere"; exit 1; }

# 5. Gate evaluation events present
grep -q "GateEvaluated" "$RELAY_ROOT/.method/events.ndjson" \
  || { echo "FAIL: no GateEvaluated events"; exit 1; }

# 6. All 4 phases completed
PHASE_COUNT=$(grep -c "PhaseCompleted" "$RELAY_ROOT/.method/events.ndjson")
test "$PHASE_COUNT" -ge 4 || { echo "FAIL: expected 4+ PhaseCompleted, got $PHASE_COUNT"; exit 1; }

echo ""
echo "=== ALL E2E CHECKS PASSED ==="
```

- [ ] **Step 2: Run the test (expecting it to work once Tasks 1-4 are complete)**

Run: `bash scripts/test/test-idea-to-ship-e2e.sh`
Expected: "ALL E2E CHECKS PASSED"

- [ ] **Step 3: Fix any issues found**

This step is iterative — the E2E test will likely reveal integration issues between the CLI flag parsing, adapter wiring, and gate evaluation. Fix each issue, re-run, repeat.

- [ ] **Step 4: Commit**

```bash
git add scripts/test/test-idea-to-ship-e2e.sh
git commit -m "test(e2e): add full idea-to-ship end-to-end integration test with real adapters"
```

---

## Task 6: Run kernel checkpoint scenario test

**Files:**
- Create: `core/capacitor-core/tests/run_kernel_checkpoint_scenario.rs`

Validate the run kernel's checkpoint emission path with a realistic multi-phase scenario that mirrors the idea-to-ship flow, including media artifacts and decision submission.

- [ ] **Step 1: Write the scenario test**

Uses `CoreRuntime` and `MutateRunCommand` — matching the pattern from `tests/run_kernel_contract.rs`:

```rust
//! Realistic run kernel checkpoint scenario: idea-to-ship.
//!
//! Verifies: Create → AttachSession → AdvancePhase →
//! EmitCheckpoint (with mermaid) → SubmitDecision →
//! AdvancePhase → EmitCheckpoint → SubmitDecision → Complete

use capacitor_core::domain::{
    CheckpointKind, InvolvementLevel, MermaidSource, MutateRunCommand,
    RunMutationKind, RunStatus,
};
use capacitor_core::CoreRuntime;

const PROJECT: &str = "/test/idea-to-ship";

fn base_cmd(run_id: &str) -> MutateRunCommand {
    MutateRunCommand {
        kind: RunMutationKind::Create, // overridden by mutate()
        project_path: PROJECT.to_string(),
        run_id: run_id.to_string(),
        method_id: None,
        involvement: None,
        checkpoint_kind: None,
        checkpoint_title: None,
        checkpoint_summary: None,
        checkpoint_brief_path: None,
        checkpoint_manifest_path: None,
        checkpoint_media_artifacts: vec![],
        checkpoint_mermaid_sources: vec![],
        capture_url: None,
        checkpoint_id: None,
        capture_request_id: None,
        client_id: None,
        observed_capture_url: None,
        capture_failure_reason: None,
        decision_action: None,
        decision_note: None,
        session_id: None,
        delegation_worker_id: None,
        completed_media_artifacts: vec![],
    }
}

fn mutate(
    runtime: &CoreRuntime,
    mut cmd: MutateRunCommand,
    kind: RunMutationKind,
) -> capacitor_core::domain::MutationOutcome {
    cmd.kind = kind;
    runtime.mutate_run(cmd).expect("mutation should not error")
}

#[test]
fn idea_to_ship_checkpoint_flow() {
    let runtime = CoreRuntime::new().expect("runtime");

    // 1. Create run with "shape_and_execute" method (has Shape + Execute phases)
    let mut cmd = base_cmd("run-its-01");
    cmd.method_id = Some("shape_and_execute".to_string());
    let result = mutate(&runtime, cmd, RunMutationKind::Create);
    assert!(result.ok, "create failed: {}", result.message);

    // 2. Attach session → activates run
    let mut cmd = base_cmd("run-its-01");
    cmd.session_id = Some("session-its".to_string());
    let result = mutate(&runtime, cmd, RunMutationKind::AttachSession);
    assert!(result.ok);

    let snap = runtime.app_snapshot().expect("snapshot");
    assert_eq!(snap.runs[0].status, RunStatus::Active);

    // 3. Emit proposal checkpoint in Shape phase (active after AttachSession)
    let mut cmd = base_cmd("run-its-01");
    cmd.checkpoint_kind = Some(CheckpointKind::Proposal);
    cmd.checkpoint_title = Some("Requirements Analysis".to_string());
    cmd.checkpoint_summary = Some("Analyzed idea, 3 risks identified".to_string());
    cmd.checkpoint_manifest_path = Some("/path/to/manifest.json".to_string());
    cmd.checkpoint_mermaid_sources = vec![MermaidSource {
        label: "Architecture".to_string(),
        source: "graph TD; A[Idea] --> B[Shape]; B --> C[Build]; C --> D[Ship]".to_string(),
    }];
    let result = mutate(&runtime, cmd, RunMutationKind::EmitCheckpoint);
    assert!(result.ok, "emit checkpoint failed: {}", result.message);

    // Verify: run paused with active checkpoint
    let snap = runtime.app_snapshot().expect("snapshot");
    assert_eq!(snap.runs[0].status, RunStatus::Paused);
    let ckpt = snap.runs[0].active_checkpoint.as_ref().expect("checkpoint");
    assert_eq!(ckpt.kind, CheckpointKind::Proposal);
    assert_eq!(ckpt.title, "Requirements Analysis");
    assert_eq!(ckpt.mermaid_sources.len(), 1);
    assert!(ckpt.manifest_path.is_some());

    // 4. Submit approval decision
    let mut cmd = base_cmd("run-its-01");
    cmd.decision_action = Some("approve".to_string());
    cmd.decision_note = Some("Shape approved, proceed to build".to_string());
    let result = mutate(&runtime, cmd, RunMutationKind::SubmitDecision);
    assert!(result.ok, "submit decision failed: {}", result.message);

    // Verify: run active again, checkpoint cleared
    let snap = runtime.app_snapshot().expect("snapshot");
    assert_eq!(snap.runs[0].status, RunStatus::Active);
    assert!(snap.runs[0].active_checkpoint.is_none());

    // 5. Advance past Shape → Execute phase
    let result = mutate(&runtime, base_cmd("run-its-01"), RunMutationKind::AdvancePhase);
    assert!(result.ok);

    // 6. Emit implementation milestone in Execute phase
    let mut cmd = base_cmd("run-its-01");
    cmd.checkpoint_kind = Some(CheckpointKind::ImplementationMilestone);
    cmd.checkpoint_title = Some("Feature implementation complete".to_string());
    cmd.checkpoint_summary = Some("All tests pass, 5 files changed".to_string());
    let result = mutate(&runtime, cmd, RunMutationKind::EmitCheckpoint);
    assert!(result.ok);

    let snap = runtime.app_snapshot().expect("snapshot");
    assert_eq!(snap.runs[0].status, RunStatus::Paused);
    let ckpt = snap.runs[0].active_checkpoint.as_ref().unwrap();
    assert_eq!(ckpt.kind, CheckpointKind::ImplementationMilestone);

    // 7. Approve → advance past last phase → run completes
    let mut cmd = base_cmd("run-its-01");
    cmd.decision_action = Some("approve".to_string());
    let result = mutate(&runtime, cmd, RunMutationKind::SubmitDecision);
    assert!(result.ok);

    let result = mutate(&runtime, base_cmd("run-its-01"), RunMutationKind::AdvancePhase);
    assert!(result.ok);

    let snap = runtime.app_snapshot().expect("snapshot");
    assert_eq!(snap.runs[0].status, RunStatus::Completed);
}
```

- [ ] **Step 2: Run test**

Run: `cargo test -p capacitor-core idea_to_ship_checkpoint_flow -- --nocapture`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add core/capacitor-core/tests/run_kernel_checkpoint_scenario.rs
git commit -m "test(run-kernel): add idea-to-ship checkpoint scenario validating full emission+decision flow"
```

---

## Task 7: Manifest format compatibility test

**Files:**
- Create: `core/capacitor-core/tests/method_runner/manifest_swift_compat.rs`
- Modify: `core/capacitor-core/tests/method_runner/mod.rs`

Verify that the Rust `CheckpointManifest` output is byte-compatible with what the Swift `DelegationReviewManifest` decoder expects.

- [ ] **Step 1: Write the compatibility test**

```rust
//! Verify manifest JSON matches Swift DelegationReviewManifest decoder expectations.

use capacitor_core::method_runner::checkpoint_manifest::CheckpointManifest;

#[test]
fn manifest_matches_swift_decoder_expectations() {
    let manifest = CheckpointManifest::new("build-gate")
        .summary("Build complete. 5 files changed.")
        .artifact("Implementation", "artifacts/impl.md", "text")
        .artifact("Screenshot", "artifacts/screen.png", "screenshot")
        .artifact("Architecture", "artifacts/arch.png", "mermaid")
        .decision_hint_approve("Ship it", "All tests pass")
        .decision_hint_request_changes("Needs work", "See issues");

    let json = manifest.to_json_pretty().unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();

    // Swift decoder expects these exact field names (snake_case):
    assert!(parsed["version"].is_number(), "version must be number");
    assert!(parsed["milestone_id"].is_string(), "milestone_id must be string");
    assert!(parsed["summary"].is_string(), "summary must be string");

    let artifacts = parsed["artifacts"].as_array().unwrap();
    for artifact in artifacts {
        assert!(artifact["label"].is_string(), "artifact.label required");
        assert!(artifact["path"].is_string(), "artifact.path required");
        // artifact_type is optional but when present must be string
        if !artifact["artifact_type"].is_null() {
            assert!(artifact["artifact_type"].is_string());
        }
    }

    // Decisions use snake_case field names matching Swift CodingKeys
    let decisions = &parsed["decisions"];
    assert!(decisions["approve"]["label"].is_string());
    assert!(decisions["approve"]["description"].is_string());
    assert!(decisions["request_changes"]["label"].is_string());
    assert!(decisions["request_changes"]["description"].is_string());

    // Verify artifact_type values match Swift's ArtifactType enum cases
    let types: Vec<&str> = artifacts.iter()
        .filter_map(|a| a["artifact_type"].as_str())
        .collect();
    let valid_types = ["text", "screenshot", "recording", "mermaid", "mermaid_diagram"];
    for t in &types {
        assert!(valid_types.contains(t), "invalid artifact_type: {}", t);
    }
}
```

- [ ] **Step 2: Run and verify**

Run: `cargo test -p capacitor-core manifest_matches_swift -- --nocapture`
Expected: PASS

- [ ] **Step 3: Run full regression**

Run: `cargo fmt && cargo clippy -- -D warnings && cargo test -p capacitor-core`
Expected: all pass

- [ ] **Step 4: Commit**

```bash
git add core/capacitor-core/tests/method_runner/manifest_swift_compat.rs \
        core/capacitor-core/tests/method_runner/mod.rs
git commit -m "test(manifest): verify Rust checkpoint manifest format matches Swift DelegationReviewManifest decoder"
```

---

## Dependency Graph

```
Task 1 (wire real adapters to CLI)
  ↓
Task 2 (FileInteractiveIO)
  ↓
Task 3 (idea-to-ship YAML) ← no code deps, but Task 5 needs it
  ↓
Task 4 (checkpoint manifest generator)
  ↓
Task 5 (E2E integration test) ← depends on Tasks 1-4
  |
Task 6 (run kernel scenario) ← independent, can run in parallel with 1-5
  |
Task 7 (manifest compat test) ← depends on Task 4
```

**Recommended execution order:** Tasks 1→2→3→4→5 sequentially, then 6 and 7 can run after 4.
