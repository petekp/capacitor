use serde_json::json;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

struct MappingCase {
    hook_event_name: &'static str,
    input_patch: serde_json::Value,
    expected_state: Option<&'static str>,
}

fn unique_temp_dir(prefix: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::from_secs(0))
        .as_nanos();
    let path = std::env::temp_dir().join(format!("{}-{}", prefix, nanos));
    fs::create_dir_all(&path).expect("create temp dir");
    path
}

fn run_handle(
    input: serde_json::Value,
    home: &Path,
    snapshot_path: &Path,
    enabled: bool,
) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_hud-hook"))
        .arg("handle")
        .env("HOME", home)
        .env("CAPACITOR_CORE_SNAPSHOT", snapshot_path)
        .env("CAPACITOR_CORE_ENABLED", if enabled { "1" } else { "0" })
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn hud-hook handle");

    {
        let stdin = child.stdin.as_mut().expect("stdin handle");
        let payload = serde_json::to_vec(&input).expect("serialize hook input");
        use std::io::Write as _;
        stdin.write_all(&payload).expect("write hook input");
    }

    child.wait_with_output().expect("wait for hud-hook")
}

fn read_snapshot(snapshot_path: &Path) -> serde_json::Value {
    let payload = fs::read_to_string(snapshot_path).expect("snapshot payload");
    serde_json::from_str(&payload).expect("valid snapshot json")
}

#[test]
fn session_state_mapping_gate_ss_p0_1_exhaustive_known_hook_events_map_to_expected_snapshot_states()
{
    let cases = vec![
        MappingCase {
            hook_event_name: "SessionStart",
            input_patch: json!({}),
            expected_state: Some("ready"),
        },
        MappingCase {
            hook_event_name: "SessionEnd",
            input_patch: json!({}),
            expected_state: None,
        },
        MappingCase {
            hook_event_name: "UserPromptSubmit",
            input_patch: json!({}),
            expected_state: Some("working"),
        },
        MappingCase {
            hook_event_name: "PreToolUse",
            input_patch: json!({"tool_name": "Edit"}),
            expected_state: Some("working"),
        },
        MappingCase {
            hook_event_name: "PostToolUse",
            input_patch: json!({"tool_name": "Edit"}),
            expected_state: Some("working"),
        },
        MappingCase {
            hook_event_name: "PostToolUseFailure",
            input_patch: json!({"tool_name": "Edit"}),
            expected_state: Some("working"),
        },
        MappingCase {
            hook_event_name: "PermissionRequest",
            input_patch: json!({}),
            expected_state: Some("waiting"),
        },
        MappingCase {
            hook_event_name: "PreCompact",
            input_patch: json!({}),
            expected_state: Some("compacting"),
        },
        MappingCase {
            hook_event_name: "Notification",
            input_patch: json!({"notification_type": "idle_prompt"}),
            expected_state: Some("ready"),
        },
        MappingCase {
            hook_event_name: "SubagentStart",
            input_patch: json!({}),
            expected_state: None,
        },
        MappingCase {
            hook_event_name: "SubagentStop",
            input_patch: json!({}),
            expected_state: None,
        },
        MappingCase {
            hook_event_name: "Stop",
            input_patch: json!({"stop_hook_active": false}),
            expected_state: Some("ready"),
        },
        MappingCase {
            hook_event_name: "TeammateIdle",
            input_patch: json!({}),
            expected_state: None,
        },
        MappingCase {
            hook_event_name: "TaskCompleted",
            input_patch: json!({}),
            expected_state: Some("ready"),
        },
        MappingCase {
            hook_event_name: "WorktreeCreate",
            input_patch: json!({}),
            expected_state: None,
        },
        MappingCase {
            hook_event_name: "WorktreeRemove",
            input_patch: json!({}),
            expected_state: None,
        },
        MappingCase {
            hook_event_name: "ConfigChange",
            input_patch: json!({}),
            expected_state: None,
        },
    ];

    for case in cases {
        let temp_dir = unique_temp_dir("hud-hook-mapping-gate");
        let snapshot_path = temp_dir.join("snapshot.json");

        let mut input = json!({
            "hook_event_name": case.hook_event_name,
            "session_id": "session-gate",
            "cwd": "/tmp/hud-hook-gate"
        });

        if let (Some(target), Some(patch)) = (input.as_object_mut(), case.input_patch.as_object()) {
            for (key, value) in patch {
                target.insert(key.clone(), value.clone());
            }
        }

        let output = run_handle(input, &temp_dir, &snapshot_path, true);
        assert!(
            output.status.success(),
            "expected hud-hook handle success for {}, stderr={}",
            case.hook_event_name,
            String::from_utf8_lossy(&output.stderr)
        );

        let snapshot = read_snapshot(&snapshot_path);
        assert_eq!(
            snapshot["diagnostics"]["events_ingested"].as_u64(),
            Some(1),
            "events_ingested should increment for {}",
            case.hook_event_name
        );

        match case.expected_state {
            Some(expected_state) => {
                assert_eq!(snapshot["sessions"].as_array().map(Vec::len), Some(1));
                let actual_state = snapshot["sessions"][0]["state"].as_str();
                assert_eq!(actual_state, Some(expected_state));
            }
            None => {
                assert_eq!(snapshot["sessions"].as_array().map(Vec::len), Some(0));
            }
        }
    }
}

#[test]
fn session_state_mapping_gate_ss_p0_1_unknown_event_is_unhandled_unknown_and_not_persisted() {
    let temp_dir = unique_temp_dir("hud-hook-mapping-unknown");
    let snapshot_path = temp_dir.join("snapshot.json");

    let output = run_handle(
        json!({
            "hook_event_name": "SomeFutureHookEvent",
            "session_id": "session-gate",
            "cwd": "/tmp/hud-hook-gate"
        }),
        &temp_dir,
        &snapshot_path,
        true,
    );

    assert!(
        output.status.success(),
        "unknown hook events should be tolerated without persistence, stderr={}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        !snapshot_path.exists(),
        "unknown event should not create snapshot side effects"
    );
}

#[test]
fn session_state_mapping_gate_ss_p1_1_subagent_stop_is_isolated_from_parent_state() {
    let temp_dir = unique_temp_dir("hud-hook-subagent-stop");
    let snapshot_path = temp_dir.join("snapshot.json");

    let first = run_handle(
        json!({
            "hook_event_name": "UserPromptSubmit",
            "session_id": "session-gate",
            "cwd": "/tmp/hud-hook-gate"
        }),
        &temp_dir,
        &snapshot_path,
        true,
    );
    assert!(first.status.success());

    let second = run_handle(
        json!({
            "hook_event_name": "Stop",
            "session_id": "session-gate",
            "cwd": "/tmp/hud-hook-gate",
            "stop_hook_active": false,
            "agent_id": "agent-123"
        }),
        &temp_dir,
        &snapshot_path,
        true,
    );
    assert!(second.status.success());

    let snapshot = read_snapshot(&snapshot_path);
    assert_eq!(snapshot["sessions"][0]["state"].as_str(), Some("working"));
    assert_eq!(snapshot["diagnostics"]["events_ingested"].as_u64(), Some(1));
}

#[test]
fn session_state_mapping_gate_ss_p1_2_unknown_notification_type_is_non_mutating_but_persisted() {
    let temp_dir = unique_temp_dir("hud-hook-unknown-notification");
    let snapshot_path = temp_dir.join("snapshot.json");

    let output = run_handle(
        json!({
            "hook_event_name": "Notification",
            "session_id": "session-gate",
            "cwd": "/tmp/hud-hook-gate",
            "notification_type": "some_future_notification"
        }),
        &temp_dir,
        &snapshot_path,
        true,
    );

    assert!(
        output.status.success(),
        "notification should be accepted for reducer-side classification, stderr={}",
        String::from_utf8_lossy(&output.stderr)
    );

    let snapshot = read_snapshot(&snapshot_path);
    assert_eq!(snapshot["diagnostics"]["events_ingested"].as_u64(), Some(1));
    assert_eq!(snapshot["sessions"].as_array().map(Vec::len), Some(0));
}

#[test]
fn session_state_mapping_gate_ss_p2_2_cli_determinism_same_input_yields_same_state_projection() {
    let temp_dir = unique_temp_dir("hud-hook-determinism");

    for idx in 0..2 {
        let snapshot_path = temp_dir.join(format!("snapshot-{}.json", idx));
        let output = run_handle(
            json!({
                "hook_event_name": "TaskCompleted",
                "session_id": "session-gate",
                "cwd": "/tmp/hud-hook-gate"
            }),
            &temp_dir,
            &snapshot_path,
            true,
        );
        assert!(
            output.status.success(),
            "task completed run {} should succeed, stderr={}",
            idx,
            String::from_utf8_lossy(&output.stderr)
        );

        let snapshot = read_snapshot(&snapshot_path);
        assert_eq!(snapshot["sessions"][0]["state"].as_str(), Some("ready"));
        assert_eq!(
            snapshot["sessions"][0]["session_id"].as_str(),
            Some("session-gate")
        );
    }
}
