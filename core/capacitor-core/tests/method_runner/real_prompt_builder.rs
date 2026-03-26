//! Integration tests for ShellPromptBuilder (IF1): T1–T12, T24, T28, T29.
//!
//! Tests exercise the real `compose-prompt.sh` script against a temp HOME
//! directory with fabricated skill and template files.

use std::path::PathBuf;
use std::time::Duration;

use capacitor_core::method_runner::adapter_config::AdapterConfig;
use capacitor_core::method_runner::adapters::{AdapterError, PromptBuildRequest, PromptBuilder};
use capacitor_core::method_runner::prompt_builder_adapter::ShellPromptBuilder;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn compose_script_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../scripts/relay/compose-prompt.sh")
        .canonicalize()
        .expect("compose-prompt.sh must exist")
}

/// Create a fake codex binary that just prints a version string.
fn create_fake_codex(dir: &std::path::Path) -> PathBuf {
    let codex_path = dir.join("fake-codex");
    std::fs::write(&codex_path, "#!/bin/bash\necho 'codex 0.1.0-test'\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&codex_path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    codex_path
}

/// Set up a temp HOME with a skill file and a template file.
/// Returns (tmp_dir_guard, home_path).
fn setup_temp_home() -> (tempfile::TempDir, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();

    // Create skill: test-skill
    let skill_dir = home.join(".claude/skills/test-skill");
    std::fs::create_dir_all(&skill_dir).unwrap();
    std::fs::write(
        skill_dir.join("SKILL.md"),
        "# Test Skill\nThis is a test skill for IF1 integration tests.\n",
    )
    .unwrap();

    // Create template: implement
    let template_dir = home.join(".claude/skills/manage-codex/references");
    std::fs::create_dir_all(&template_dir).unwrap();
    std::fs::write(
        template_dir.join("implement-template.md"),
        "# Implementation Template\nBuild the requested feature.\n",
    )
    .unwrap();

    // Create relay-protocol.md (used by compose-prompt legacy fallback)
    std::fs::write(
        template_dir.join("relay-protocol.md"),
        "### Files Changed\n- placeholder\n\n### Tests Run\n- placeholder\n\n### Completion Claim\nCOMPLETE\n",
    )
    .unwrap();

    (tmp, home)
}

/// Build an AdapterConfig using the temp HOME.
fn make_config(home: &std::path::Path) -> AdapterConfig {
    let codex = create_fake_codex(home);
    AdapterConfig::new(
        compose_script_path(),
        codex,
        home.to_path_buf(),
        Duration::from_secs(300),
        Duration::from_secs(5),
    )
    .unwrap()
}

/// Build a builder + request, setting HOME to the temp dir.
fn make_builder_and_request(
    home: &std::path::Path,
    relay_root: PathBuf,
    template: Option<String>,
    skills: Vec<String>,
) -> (ShellPromptBuilder, PromptBuildRequest) {
    // Override HOME so compose-prompt.sh resolves skills/templates from our temp dir
    std::env::set_var("HOME", home);

    let config = make_config(home);
    let builder = ShellPromptBuilder::new(config);

    let request = PromptBuildRequest {
        phase_id: "p1".into(),
        step_id: "s1".into(),
        attempt: 1,
        relay_root,
        instructions: "Build the primary artifact.".into(),
        template,
        skills,
        context_file: None,
    };

    (builder, request)
}

// =========================================================================
// T1: Happy path with real compose-prompt.sh
// =========================================================================

#[test]
fn t1_happy_path_real_compose_prompt() {
    let (_tmp_home, home) = setup_temp_home();
    let relay_tmp = tempfile::tempdir().unwrap();
    let relay_root = relay_tmp.path().join("relay");

    let (builder, request) = make_builder_and_request(
        &home,
        relay_root.clone(),
        Some("implement".into()),
        vec!["test-skill".into()],
    );

    let result = builder.build_prompt(&request).unwrap();

    // prompt.md should exist and contain assembled content
    assert!(result.prompt_path.exists(), "prompt.md must exist");
    let prompt = std::fs::read_to_string(&result.prompt_path).unwrap();
    assert!(
        prompt.contains("Build the primary artifact"),
        "prompt should contain instructions"
    );
    assert!(
        prompt.contains("Test Skill"),
        "prompt should contain skill content"
    );
    assert!(
        prompt.contains("Implementation Template"),
        "prompt should contain template content"
    );
}

// =========================================================================
// T2: Missing skill path → SkillNotFound before subprocess spawn
// =========================================================================

#[test]
fn t2_missing_skill_fails_before_spawn() {
    let (_tmp_home, home) = setup_temp_home();
    let relay_tmp = tempfile::tempdir().unwrap();
    let relay_root = relay_tmp.path().join("relay");

    let (builder, request) =
        make_builder_and_request(&home, relay_root, None, vec!["nonexistent-skill".into()]);

    let result = builder.build_prompt(&request);
    assert!(result.is_err());
    match result.unwrap_err() {
        AdapterError::SkillNotFound(msg) => {
            assert!(
                msg.contains("nonexistent-skill"),
                "should name the skill: {msg}"
            );
        }
        other => panic!("expected SkillNotFound, got: {other:?}"),
    }
}

// =========================================================================
// T3: Missing template path → TemplateNotFound before subprocess spawn
// =========================================================================

#[test]
fn t3_missing_template_fails_before_spawn() {
    let (_tmp_home, home) = setup_temp_home();
    let relay_tmp = tempfile::tempdir().unwrap();
    let relay_root = relay_tmp.path().join("relay");

    let (builder, request) = make_builder_and_request(
        &home,
        relay_root,
        Some("nonexistent-template".into()),
        vec![],
    );

    let result = builder.build_prompt(&request);
    assert!(result.is_err());
    match result.unwrap_err() {
        AdapterError::TemplateNotFound(msg) => {
            assert!(
                msg.contains("nonexistent-template"),
                "should name the template: {msg}"
            );
        }
        other => panic!("expected TemplateNotFound, got: {other:?}"),
    }
}

// =========================================================================
// T4: Script exits non-zero → AssemblyFailed
// =========================================================================

#[test]
fn t4_script_nonzero_exit_returns_assembly_failed() {
    let (_tmp_home, home) = setup_temp_home();
    let relay_tmp = tempfile::tempdir().unwrap();
    let relay_root = relay_tmp.path().join("relay");

    // Create a broken compose-prompt script that always exits 1
    let broken_script = relay_tmp.path().join("broken-compose.sh");
    std::fs::write(&broken_script, "#!/bin/bash\necho 'BOOM' >&2\nexit 1\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&broken_script, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    std::env::set_var("HOME", &home);
    let codex = create_fake_codex(&home);
    let config = AdapterConfig::new(
        broken_script,
        codex,
        home.clone(),
        Duration::from_secs(300),
        Duration::from_secs(5),
    )
    .unwrap();

    let builder = ShellPromptBuilder::new(config);
    let request = PromptBuildRequest {
        phase_id: "p1".into(),
        step_id: "s1".into(),
        attempt: 1,
        relay_root,
        instructions: "Build it.".into(),
        template: None,
        skills: vec![],
        context_file: None,
    };

    let result = builder.build_prompt(&request);
    assert!(result.is_err());
    match result.unwrap_err() {
        AdapterError::AssemblyFailed { exit_code, stderr } => {
            assert_ne!(exit_code, 0);
            assert!(
                stderr.contains("BOOM"),
                "stderr should contain script output: {stderr}"
            );
        }
        other => panic!("expected AssemblyFailed, got: {other:?}"),
    }
}

// =========================================================================
// T5: Script exits 0 but omits output file → ContractViolation
// =========================================================================

#[test]
fn t5_script_exit_zero_no_output_returns_contract_violation() {
    let (_tmp_home, home) = setup_temp_home();
    let relay_tmp = tempfile::tempdir().unwrap();
    let relay_root = relay_tmp.path().join("relay");

    // Script that exits 0 but writes nothing to --out
    let noop_script = relay_tmp.path().join("noop-compose.sh");
    std::fs::write(
        &noop_script,
        "#!/bin/bash\n# Intentionally does not create the output file\nexit 0\n",
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&noop_script, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    std::env::set_var("HOME", &home);
    let codex = create_fake_codex(&home);
    let config = AdapterConfig::new(
        noop_script,
        codex,
        home.clone(),
        Duration::from_secs(300),
        Duration::from_secs(5),
    )
    .unwrap();

    let builder = ShellPromptBuilder::new(config);
    let request = PromptBuildRequest {
        phase_id: "p1".into(),
        step_id: "s1".into(),
        attempt: 1,
        relay_root,
        instructions: "Build it.".into(),
        template: None,
        skills: vec![],
        context_file: None,
    };

    let result = builder.build_prompt(&request);
    assert!(result.is_err());
    match result.unwrap_err() {
        AdapterError::ContractViolation(msg) => {
            assert!(
                msg.contains("prompt.md"),
                "should mention the missing file: {msg}"
            );
        }
        other => panic!("expected ContractViolation, got: {other:?}"),
    }
}

// =========================================================================
// T6: Same request twice → byte-identical prompt output
// =========================================================================

#[test]
fn t6_idempotent_output() {
    let (_tmp_home, home) = setup_temp_home();

    let relay_tmp1 = tempfile::tempdir().unwrap();
    let relay_tmp2 = tempfile::tempdir().unwrap();

    std::env::set_var("HOME", &home);
    let config = make_config(&home);

    let builder = ShellPromptBuilder::new(config);

    let request1 = PromptBuildRequest {
        phase_id: "p1".into(),
        step_id: "s1".into(),
        attempt: 1,
        relay_root: relay_tmp1.path().join("relay"),
        instructions: "Build the artifact.".into(),
        template: Some("implement".into()),
        skills: vec!["test-skill".into()],
        context_file: None,
    };

    let mut request2 = request1.clone();
    request2.relay_root = relay_tmp2.path().join("relay");

    let result1 = builder.build_prompt(&request1).unwrap();
    let result2 = builder.build_prompt(&request2).unwrap();

    let prompt1 = std::fs::read(&result1.prompt_path).unwrap();
    let prompt2 = std::fs::read(&result2.prompt_path).unwrap();
    assert_eq!(prompt1, prompt2, "prompts must be byte-identical");
}

// =========================================================================
// T7: Metadata JSON
// =========================================================================

#[test]
fn t7_metadata_json_written() {
    let (_tmp_home, home) = setup_temp_home();
    let relay_tmp = tempfile::tempdir().unwrap();
    let relay_root = relay_tmp.path().join("relay");

    let (builder, request) = make_builder_and_request(&home, relay_root.clone(), None, vec![]);

    let _result = builder.build_prompt(&request).unwrap();

    let metadata_path = relay_root.join("adapter/prompt-builder.metadata.json");
    assert!(metadata_path.exists(), "metadata JSON must be written");

    let metadata: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&metadata_path).unwrap()).unwrap();

    assert!(metadata["argv"].is_array(), "should have argv");
    assert!(metadata["exit_code"].is_number(), "should have exit_code");
    assert!(metadata["elapsed_ms"].is_number(), "should have elapsed_ms");
    assert!(
        metadata["header_path"].is_string(),
        "should have header_path"
    );
    assert!(
        metadata["prompt_path"].is_string(),
        "should have prompt_path"
    );
}

// =========================================================================
// T8: Stderr capture
// =========================================================================

#[test]
fn t8_stderr_captured() {
    let (_tmp_home, home) = setup_temp_home();
    let relay_tmp = tempfile::tempdir().unwrap();
    let relay_root = relay_tmp.path().join("relay");

    // Use a script that writes a warning to stderr but still succeeds
    let warn_script = relay_tmp.path().join("warn-compose.sh");
    std::fs::write(
        &warn_script,
        "#!/bin/bash\n\
         # Parse args to find --header and --out\n\
         HEADER=\"\"; OUT=\"\"\n\
         while [[ $# -gt 0 ]]; do\n\
           case \"$1\" in\n\
             --header) HEADER=\"$2\"; shift 2 ;;\n\
             --out) OUT=\"$2\"; shift 2 ;;\n\
             *) shift ;;\n\
           esac\n\
         done\n\
         echo 'WARNING: test warning message' >&2\n\
         cp \"$HEADER\" \"$OUT\"\n\
         exit 0\n",
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&warn_script, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    std::env::set_var("HOME", &home);
    let codex = create_fake_codex(&home);
    let config = AdapterConfig::new(
        warn_script,
        codex,
        home.clone(),
        Duration::from_secs(300),
        Duration::from_secs(5),
    )
    .unwrap();

    let builder = ShellPromptBuilder::new(config);
    let request = PromptBuildRequest {
        phase_id: "p1".into(),
        step_id: "s1".into(),
        attempt: 1,
        relay_root: relay_root.clone(),
        instructions: "Build it.".into(),
        template: None,
        skills: vec![],
        context_file: None,
    };

    let _result = builder.build_prompt(&request).unwrap();

    let stderr_path = relay_root.join("adapter/prompt-builder.stderr.log");
    assert!(stderr_path.exists(), "stderr log must be written");
    let stderr = std::fs::read_to_string(&stderr_path).unwrap();
    assert!(
        stderr.contains("WARNING: test warning message"),
        "stderr should contain the warning: {stderr}"
    );
}

// =========================================================================
// T24: First real adapter call writes preflight record
// =========================================================================

#[test]
fn t24_preflight_json_written_on_first_call() {
    let (_tmp_home, home) = setup_temp_home();
    let relay_tmp = tempfile::tempdir().unwrap();
    let relay_root = relay_tmp.path().join("relay");

    let (builder, request) = make_builder_and_request(&home, relay_root.clone(), None, vec![]);

    // Before call: no preflight
    let preflight_path = relay_root.join("adapter/preflight.json");
    assert!(
        !preflight_path.exists(),
        "preflight should not exist before first call"
    );

    let _result = builder.build_prompt(&request).unwrap();

    assert!(
        preflight_path.exists(),
        "preflight.json must exist after first call"
    );
    let preflight: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&preflight_path).unwrap()).unwrap();
    assert!(
        preflight["script_path"].is_string(),
        "preflight should have script_path"
    );
    assert!(
        preflight["codex_path"].is_string(),
        "preflight should have codex_path"
    );
}

// =========================================================================
// T28: IF1 absolute paths — all subprocess file args are absolute
// =========================================================================

#[test]
fn t28_all_file_args_are_absolute() {
    let (_tmp_home, home) = setup_temp_home();
    let relay_tmp = tempfile::tempdir().unwrap();
    let relay_root = relay_tmp.path().join("relay");

    let (builder, request) = make_builder_and_request(
        &home,
        relay_root.clone(),
        Some("implement".into()),
        vec!["test-skill".into()],
    );

    let _result = builder.build_prompt(&request).unwrap();

    // Read metadata to verify all paths in argv are absolute
    let metadata_path = relay_root.join("adapter/prompt-builder.metadata.json");
    let metadata: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&metadata_path).unwrap()).unwrap();

    let argv = metadata["argv"].as_array().unwrap();

    // Check --header and --out args are absolute paths
    for (i, arg) in argv.iter().enumerate() {
        let val = arg.as_str().unwrap();
        if val == "--header" || val == "--out" || val == "--root" {
            let next = argv[i + 1].as_str().unwrap();
            assert!(
                std::path::Path::new(next).is_absolute(),
                "arg after {} must be absolute, got: {}",
                val,
                next
            );
        }
    }

    // Also verify the result paths are absolute
    let result = builder
        .build_prompt(&PromptBuildRequest {
            relay_root: relay_tmp.path().join("relay2"),
            ..request
        })
        .unwrap();
    assert!(
        result.header_path.is_absolute(),
        "header_path must be absolute"
    );
    assert!(
        result.prompt_path.is_absolute(),
        "prompt_path must be absolute"
    );
}

// =========================================================================
// T29: IF1 allowlisted env — subprocess env contains only allowlisted keys
// =========================================================================

#[test]
fn t29_allowlisted_env_only() {
    // This test verifies that compose-prompt.sh runs with a filtered env.
    // We can't directly inspect the subprocess env, but we can verify the
    // adapter constructs the env correctly by checking build_allowed_env.
    use capacitor_core::method_runner::adapter_config::build_allowed_env;

    // Set a non-allowlisted variable
    std::env::set_var("__IF1_TEST_SECRET", "should_not_leak");

    let env = build_allowed_env(&[]);
    let keys: Vec<&str> = env.iter().map(|(k, _)| k.as_str()).collect();

    assert!(
        !keys.contains(&"__IF1_TEST_SECRET"),
        "non-allowlisted key must not appear in subprocess env"
    );

    // Only allowlisted keys should be present
    let allowed = [
        "PATH",
        "HOME",
        "USER",
        "SHELL",
        "LANG",
        "LC_ALL",
        "TERM",
        "TMPDIR",
        "XDG_RUNTIME_DIR",
    ];
    for key in &keys {
        assert!(allowed.contains(key), "unexpected key in env: {}", key);
    }

    std::env::remove_var("__IF1_TEST_SECRET");
}

// =========================================================================
// T9-T12: context_file handling
// =========================================================================

#[test]
fn t9_context_file_with_title_and_description_prepended_to_header() {
    let (tmp, home) = setup_temp_home();
    let relay_root = tmp.path().join("relay");

    let (builder, mut request) =
        make_builder_and_request(&home, relay_root, None, vec!["test-skill".into()]);

    let context_path = tmp.path().join("context.json");
    std::fs::write(
        &context_path,
        r#"{"version":1,"title":"Fix login bug","description":"The login form crashes on empty email"}"#,
    )
    .unwrap();
    request.context_file = Some(context_path);

    let result = builder.build_prompt(&request).unwrap();
    let header = std::fs::read_to_string(&result.header_path).unwrap();
    assert!(
        header.starts_with("# Task: Fix login bug"),
        "header should start with task title, got: {}",
        header
    );
    assert!(
        header.contains("The login form crashes on empty email"),
        "header should contain description"
    );
    assert!(
        header.contains("# Step: s1"),
        "header should still contain step metadata"
    );
}

#[test]
fn t10_context_file_with_empty_fields_produces_no_prefix() {
    let (tmp, home) = setup_temp_home();
    let relay_root = tmp.path().join("relay");

    let (builder, mut request) =
        make_builder_and_request(&home, relay_root, None, vec!["test-skill".into()]);

    let context_path = tmp.path().join("context.json");
    std::fs::write(
        &context_path,
        r#"{"version":1,"title":"","description":""}"#,
    )
    .unwrap();
    request.context_file = Some(context_path);

    let result = builder.build_prompt(&request).unwrap();
    let header = std::fs::read_to_string(&result.header_path).unwrap();
    assert!(
        header.starts_with("# Step: s1"),
        "empty context should produce no prefix, got: {}",
        header
    );
}

#[test]
fn t11_context_file_missing_falls_back_gracefully() {
    let (tmp, home) = setup_temp_home();
    let relay_root = tmp.path().join("relay");

    let (builder, mut request) =
        make_builder_and_request(&home, relay_root, None, vec!["test-skill".into()]);

    request.context_file = Some(tmp.path().join("nonexistent-context.json"));

    let result = builder.build_prompt(&request).unwrap();
    let header = std::fs::read_to_string(&result.header_path).unwrap();
    assert!(
        header.starts_with("# Step: s1"),
        "missing context file should fall back gracefully, got: {}",
        header
    );
}

#[test]
fn t12_context_file_malformed_json_falls_back_gracefully() {
    let (tmp, home) = setup_temp_home();
    let relay_root = tmp.path().join("relay");

    let (builder, mut request) =
        make_builder_and_request(&home, relay_root, None, vec!["test-skill".into()]);

    let context_path = tmp.path().join("context.json");
    std::fs::write(&context_path, "this is not json {{{").unwrap();
    request.context_file = Some(context_path);

    let result = builder.build_prompt(&request).unwrap();
    let header = std::fs::read_to_string(&result.header_path).unwrap();
    assert!(
        header.starts_with("# Step: s1"),
        "malformed JSON should fall back gracefully, got: {}",
        header
    );
}
