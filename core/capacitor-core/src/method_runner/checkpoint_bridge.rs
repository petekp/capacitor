//! Bridge between synchronous method-runner gate checkpoints and async run-kernel reviews.
//!
//! `BridgeInteractiveIO` implements `InteractiveIO` by writing a pending marker to disk,
//! posting an `EmitCheckpoint` mutation to the runtime service, then polling for a
//! decision file written back by the `checkpoint_bridge_relay` in hud-hook.
//! The design is fail-closed: validation failures, write errors, and mutation rejections
//! all fall back to the interactive prompt without arming a gate_id.
//! File format is defined in `checkpoint_bridge_protocol`.

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

use crate::domain::{MutateRunCommand, MutationOutcome, RunMutationKind};
use crate::method_runner::adapters::{
    GateCheckpointContext, InteractiveIO, InteractivePrompt, InteractiveResponse,
};
use crate::method_runner::checkpoint_bridge_protocol::{
    decision_path, pending_path, validate_path_component, write_json_atomic,
    CheckpointBridgeDecision, CheckpointBridgePending, CHECKPOINT_BRIDGE_PROTOCOL_VERSION,
};
use crate::runtime::service::RuntimeServiceEndpoint;

/// Maximum time to wait for a decision file before falling back to "rejected".
/// Human gate decisions can reasonably take a long time (reviewer is reading code),
/// so this is a safety net, not an expected timeout.
const DECISION_POLL_TIMEOUT: Duration = Duration::from_secs(3600); // 1 hour

pub struct BridgeInteractiveIO {
    endpoint: RuntimeServiceEndpoint,
    project_path: PathBuf,
    run_id: String,
    home_dir: PathBuf,
    fallback: Box<dyn InteractiveIO>,
    current_gate_id: RefCell<Option<String>>,
    poll_timeout: Duration,
}

impl BridgeInteractiveIO {
    pub fn new(
        endpoint: RuntimeServiceEndpoint,
        project_path: PathBuf,
        run_id: String,
        home_dir: PathBuf,
        fallback: Box<dyn InteractiveIO>,
    ) -> Self {
        Self {
            endpoint,
            project_path,
            run_id,
            home_dir,
            fallback,
            current_gate_id: RefCell::new(None),
            poll_timeout: DECISION_POLL_TIMEOUT,
        }
    }

    fn manifest_path(&self, manifest_path: &Path) -> PathBuf {
        if manifest_path.is_absolute() {
            manifest_path.to_path_buf()
        } else {
            self.project_path.join(manifest_path)
        }
    }

    fn checkpoint_command(&self, context: &GateCheckpointContext) -> MutateRunCommand {
        let manifest_path = self.manifest_path(&context.manifest_path);

        MutateRunCommand {
            kind: RunMutationKind::EmitCheckpoint,
            project_path: self.project_path.to_string_lossy().into_owned(),
            run_id: self.run_id.clone(),
            method_id: None,
            involvement: None,
            checkpoint_kind: Some(context.checkpoint_kind.clone()),
            checkpoint_title: Some(context.checkpoint_title.clone()),
            checkpoint_summary: Some(context.checkpoint_summary.clone()),
            checkpoint_brief_path: None,
            checkpoint_manifest_path: Some(manifest_path.to_string_lossy().into_owned()),
            checkpoint_media_artifacts: context.media_artifacts.clone(),
            checkpoint_mermaid_sources: context.mermaid_sources.clone(),
            capture_url: None,
            checkpoint_id: Some(context.gate_id.clone()),
            capture_request_id: None,
            client_id: None,
            observed_capture_url: None,
            capture_failure_reason: None,
            decision_action: None,
            decision_note: None,
            session_id: None,
            delegation_worker_id: None,
            status_message: None,
            idea_id: None,
            idea_title: None,
            idea_description: None,
            completed_media_artifacts: Vec::new(),
        }
    }

    fn pending_marker(&self, context: &GateCheckpointContext) -> CheckpointBridgePending {
        let manifest_path = self.manifest_path(&context.manifest_path);

        CheckpointBridgePending {
            version: CHECKPOINT_BRIDGE_PROTOCOL_VERSION,
            project_path: self.project_path.to_string_lossy().into_owned(),
            run_id: self.run_id.clone(),
            checkpoint_id: context.gate_id.clone(),
            phase_id: context.phase_id.clone(),
            gate_type: context.gate_type.clone(),
            manifest_path: manifest_path.to_string_lossy().into_owned(),
            created_at: chrono::Utc::now().to_rfc3339(),
        }
    }

    fn normalize_decision(decision: &CheckpointBridgeDecision) -> String {
        match decision.action.trim().to_ascii_lowercase().as_str() {
            "approve" | "approved" => "approved".to_string(),
            "request_changes" | "rejected" => "rejected".to_string(),
            other => {
                eprintln!(
                    "warning: unknown checkpoint bridge decision action '{}'; treating as rejected",
                    other
                );
                "rejected".to_string()
            }
        }
    }

    fn read_decision(&self, gate_id: &str) -> Result<Option<CheckpointBridgeDecision>, String> {
        let path = decision_path(&self.home_dir, &self.run_id, gate_id);
        if !path.exists() {
            return Ok(None);
        }

        let contents = fs_err::read_to_string(&path).map_err(|error| {
            format!(
                "Failed to read checkpoint bridge decision {:?}: {error}",
                path
            )
        })?;
        let decision: CheckpointBridgeDecision =
            serde_json::from_str(&contents).map_err(|error| {
                format!(
                    "Failed to parse checkpoint bridge decision {:?}: {error}",
                    path
                )
            })?;
        if decision.version != CHECKPOINT_BRIDGE_PROTOCOL_VERSION {
            return Err(format!(
                "Unsupported checkpoint bridge decision version {} for {:?}",
                decision.version, path
            ));
        }
        Ok(Some(decision))
    }

    fn delete_decision_file(&self, gate_id: &str) {
        let path = decision_path(&self.home_dir, &self.run_id, gate_id);
        if let Err(error) = fs_err::remove_file(&path) {
            if error.kind() != std::io::ErrorKind::NotFound {
                eprintln!(
                    "warning: failed to delete checkpoint bridge decision {:?}: {}",
                    path, error
                );
            }
        }
    }

    fn post_checkpoint(&self, context: &GateCheckpointContext) -> bool {
        let command = self.checkpoint_command(context);
        match self.endpoint.mutate_run(&command) {
            Ok(MutationOutcome { ok: true, .. }) => true,
            Ok(outcome) => {
                eprintln!(
                    "warning: runtime service rejected checkpoint bridge mutation for gate '{}': {}",
                    context.gate_id, outcome.message
                );
                false
            }
            Err(error) => {
                eprintln!(
                    "warning: failed to post checkpoint bridge mutation for gate '{}': {}",
                    context.gate_id, error
                );
                false
            }
        }
    }
}

impl InteractiveIO for BridgeInteractiveIO {
    fn emit_prompt(&self, prompt: &InteractivePrompt) {
        self.fallback.emit_prompt(prompt);
    }

    fn capture_response(&self) -> InteractiveResponse {
        let gate_id = {
            let current_gate_id = self.current_gate_id.borrow();
            current_gate_id.clone()
        };

        let Some(gate_id) = gate_id else {
            return self.fallback.capture_response();
        };

        let deadline = Instant::now() + self.poll_timeout;
        loop {
            match self.read_decision(&gate_id) {
                Ok(Some(decision)) => {
                    let body = Self::normalize_decision(&decision);
                    *self.current_gate_id.borrow_mut() = None;
                    self.delete_decision_file(&gate_id);
                    return InteractiveResponse { body };
                }
                Ok(None) => {
                    if Instant::now() >= deadline {
                        eprintln!(
                            "warning: checkpoint bridge decision poll timed out for gate '{}' after {:?}",
                            gate_id, self.poll_timeout
                        );
                        *self.current_gate_id.borrow_mut() = None;
                        return InteractiveResponse {
                            body: "rejected".to_string(),
                        };
                    }
                    thread::sleep(Duration::from_millis(500));
                }
                Err(error) => {
                    eprintln!("warning: {}", error);
                    *self.current_gate_id.borrow_mut() = None;
                    self.delete_decision_file(&gate_id);
                    return InteractiveResponse {
                        body: "rejected".to_string(),
                    };
                }
            }
        }
    }

    fn emit_gate_checkpoint(&self, context: &GateCheckpointContext) {
        // Validate IDs before using them as filesystem path components
        if let Err(error) = validate_path_component(&self.run_id, "run_id") {
            eprintln!(
                "warning: unsafe run_id for checkpoint bridge, falling back to prompt: {error}"
            );
            self.fallback.emit_prompt(&InteractivePrompt {
                message: context.prompt_message.clone(),
            });
            return;
        }
        if let Err(error) = validate_path_component(&context.gate_id, "gate_id") {
            eprintln!(
                "warning: unsafe gate_id for checkpoint bridge, falling back to prompt: {error}"
            );
            self.fallback.emit_prompt(&InteractivePrompt {
                message: context.prompt_message.clone(),
            });
            return;
        }

        let pending = self.pending_marker(context);
        let pending_path = pending_path(&self.home_dir, &self.run_id, &context.gate_id);

        if let Err(error) = write_json_atomic(&pending_path, &pending) {
            eprintln!(
                "warning: failed to write checkpoint bridge pending marker for gate '{}', falling back to prompt: {}",
                context.gate_id, error
            );
            self.fallback.emit_prompt(&InteractivePrompt {
                message: context.prompt_message.clone(),
            });
            return;
        }

        if !self.post_checkpoint(context) {
            // Mutation failed or was rejected — clean up pending marker and fall back
            // to the standard interactive prompt so capture_response() doesn't block
            // forever waiting for a decision file that will never arrive.
            let _ = fs_err::remove_file(&pending_path);
            self.fallback.emit_prompt(&InteractivePrompt {
                message: context.prompt_message.clone(),
            });
            return;
        }

        *self.current_gate_id.borrow_mut() = Some(context.gate_id.clone());
    }
}
