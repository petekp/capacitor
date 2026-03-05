mod common;

use common::{free_port, post_hook, read_snapshot, unique_temp_dir, ServerGuard};
use serde_json::json;

struct MappingCase {
    hook_event_name: &'static str,
    input_patch: serde_json::Value,
    expected_state: Option<&'static str>,
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

    // Each case gets its own server instance to isolate state
    for case in cases {
        let temp_dir = unique_temp_dir("hud-hook-mapping-gate");
        let snapshot_path = temp_dir.join("snapshot.json");
        let port = free_port();

        let _guard = ServerGuard::spawn(port, &temp_dir, &snapshot_path);
        ServerGuard::wait_ready(port);

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

        let (status, _body) = post_hook(port, &input);
        assert_eq!(
            status, 200,
            "expected 200 for {}, got {}",
            case.hook_event_name, status
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
    let port = free_port();

    let _guard = ServerGuard::spawn(port, &temp_dir, &snapshot_path);
    ServerGuard::wait_ready(port);

    let (status, _) = post_hook(
        port,
        &json!({
            "hook_event_name": "SomeFutureHookEvent",
            "session_id": "session-gate",
            "cwd": "/tmp/hud-hook-gate"
        }),
    );

    assert_eq!(status, 200, "unknown hook events should be tolerated");
    assert!(
        !snapshot_path.exists(),
        "unknown event should not create snapshot side effects"
    );
}

#[test]
fn session_state_mapping_gate_ss_p1_1_subagent_stop_is_isolated_from_parent_state() {
    let temp_dir = unique_temp_dir("hud-hook-subagent-stop");
    let snapshot_path = temp_dir.join("snapshot.json");
    let port = free_port();

    let _guard = ServerGuard::spawn(port, &temp_dir, &snapshot_path);
    ServerGuard::wait_ready(port);

    let (status1, _) = post_hook(
        port,
        &json!({
            "hook_event_name": "UserPromptSubmit",
            "session_id": "session-gate",
            "cwd": "/tmp/hud-hook-gate"
        }),
    );
    assert_eq!(status1, 200);

    let (status2, _) = post_hook(
        port,
        &json!({
            "hook_event_name": "Stop",
            "session_id": "session-gate",
            "cwd": "/tmp/hud-hook-gate",
            "stop_hook_active": false,
            "agent_id": "agent-123"
        }),
    );
    assert_eq!(status2, 200);

    let snapshot = read_snapshot(&snapshot_path);
    assert_eq!(snapshot["sessions"][0]["state"].as_str(), Some("working"));
    assert_eq!(snapshot["diagnostics"]["events_ingested"].as_u64(), Some(1));
}

#[test]
fn session_state_mapping_gate_ss_p1_2_unknown_notification_type_is_non_mutating_but_persisted() {
    let temp_dir = unique_temp_dir("hud-hook-unknown-notification");
    let snapshot_path = temp_dir.join("snapshot.json");
    let port = free_port();

    let _guard = ServerGuard::spawn(port, &temp_dir, &snapshot_path);
    ServerGuard::wait_ready(port);

    let (status, _) = post_hook(
        port,
        &json!({
            "hook_event_name": "Notification",
            "session_id": "session-gate",
            "cwd": "/tmp/hud-hook-gate",
            "notification_type": "some_future_notification"
        }),
    );
    assert_eq!(status, 200);

    let snapshot = read_snapshot(&snapshot_path);
    assert_eq!(snapshot["diagnostics"]["events_ingested"].as_u64(), Some(1));
    assert_eq!(snapshot["sessions"].as_array().map(Vec::len), Some(0));
}

#[test]
fn session_state_mapping_gate_ss_p2_2_cli_determinism_same_input_yields_same_state_projection() {
    let temp_dir = unique_temp_dir("hud-hook-determinism");

    for idx in 0..2 {
        let snapshot_path = temp_dir.join(format!("snapshot-{}.json", idx));
        let port = free_port();

        let _guard = ServerGuard::spawn(port, &temp_dir, &snapshot_path);
        ServerGuard::wait_ready(port);

        let (status, _) = post_hook(
            port,
            &json!({
                "hook_event_name": "TaskCompleted",
                "session_id": "session-gate",
                "cwd": "/tmp/hud-hook-gate"
            }),
        );
        assert_eq!(status, 200, "task completed run {} should succeed", idx);

        let snapshot = read_snapshot(&snapshot_path);
        assert_eq!(snapshot["sessions"][0]["state"].as_str(), Some("ready"));
        assert_eq!(
            snapshot["sessions"][0]["session_id"].as_str(),
            Some("session-gate")
        );
    }
}
