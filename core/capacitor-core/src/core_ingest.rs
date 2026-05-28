use super::*;

impl CoreRuntime {
    fn ingest_hook_event_internal(
        &self,
        command: IngestHookEventCommand,
        gc_reference_time: Option<DateTime<Utc>>,
    ) -> Result<MutationOutcome, CoreRuntimeError> {
        let normalized = ingest::normalize_hook_event(command);
        let mut state = self.lock_state()?;
        let outcome = state.apply_hook_event_with_gc_reference_time(normalized, gc_reference_time);
        self.bump_version_and_notify();
        let snapshot = state.snapshot();
        drop(state);
        self.persist_snapshot(&snapshot)?;
        Ok(outcome)
    }

    pub fn ingest_hook_event_with_gc_reference_time(
        &self,
        command: IngestHookEventCommand,
        gc_reference_time: DateTime<Utc>,
    ) -> Result<MutationOutcome, CoreRuntimeError> {
        self.ingest_hook_event_internal(command, Some(gc_reference_time))
    }

    #[allow(dead_code)] // used by cold-start reconstruction (Phase 2 step 7)
    pub(crate) fn ingest_transcript_observation(
        &self,
        discovery: crate::observation::transcript::TranscriptDiscovery,
    ) -> Result<MutationOutcome, CoreRuntimeError> {
        let mut state = self.lock_state()?;
        let outcome = state.apply_transcript_discovery(discovery);
        self.bump_version_and_notify();
        let snapshot = state.snapshot();
        drop(state);
        self.persist_snapshot(&snapshot)?;
        Ok(outcome)
    }

    pub fn unregister_shell(
        &self,
        command: domain::ShellUnregisterCommand,
    ) -> Result<MutationOutcome, CoreRuntimeError> {
        let mut state = self.lock_state()?;
        let outcome = state.apply_shell_unregister(command);
        if outcome.ok {
            self.bump_version_and_notify();
        }
        let snapshot = state.snapshot();
        drop(state);
        self.persist_snapshot(&snapshot)?;
        Ok(outcome)
    }

    pub fn mutate_run_with_commit<F>(
        &self,
        command: domain::MutateRunCommand,
        commit: F,
    ) -> Result<MutationOutcome, CoreRuntimeError>
    where
        F: FnOnce() -> Result<(), String>,
    {
        let mut state = self.lock_state()?;
        let previous_state = state.clone();
        let outcome = state.apply_run_mutation(command);

        if outcome.ok {
            if let Err(error) = commit() {
                *state = previous_state;
                return Ok(MutationOutcome {
                    ok: false,
                    message: format!("run mutation commit failed: {error}"),
                });
            }
        }

        self.bump_version_and_notify();
        let snapshot = state.snapshot();
        drop(state);
        self.persist_snapshot(&snapshot)?;
        Ok(outcome)
    }

    pub fn checkpoint_decision_relay_for(
        &self,
        command: &domain::MutateRunCommand,
    ) -> Result<Option<domain::CheckpointDecisionRelay>, CoreRuntimeError> {
        let project_path = command.project_path.trim();
        let run_id = command.run_id.trim();
        let Some(checkpoint_id) = command
            .checkpoint_id
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        else {
            return Ok(None);
        };

        if project_path.is_empty() || run_id.is_empty() {
            return Ok(None);
        }

        let key = format!("{project_path}#{run_id}");
        let state = self.lock_state()?;
        Ok(state
            .runs
            .get(&key)
            .and_then(|run| run.active_checkpoint.as_ref())
            .filter(|checkpoint| checkpoint.id == checkpoint_id)
            .and_then(|checkpoint| checkpoint.decision_relay))
    }
}

#[uniffi::export]
impl CoreRuntime {
    pub fn ingest_hook_event(
        &self,
        command: IngestHookEventCommand,
    ) -> Result<MutationOutcome, CoreRuntimeError> {
        self.ingest_hook_event_internal(command, None)
    }

    pub fn ingest_shell_signal(
        &self,
        command: IngestShellSignalCommand,
    ) -> Result<MutationOutcome, CoreRuntimeError> {
        let normalized = ingest::normalize_shell_signal(command);
        let mut state = self.lock_state()?;
        let outcome = state.apply_shell_signal(normalized);
        self.bump_version_and_notify();
        let snapshot = state.snapshot();
        drop(state);
        self.persist_snapshot(&snapshot)?;
        Ok(outcome)
    }

    pub fn mutate_project(
        &self,
        command: MutateProjectCommand,
    ) -> Result<MutationOutcome, CoreRuntimeError> {
        let mut state = self.lock_state()?;
        let outcome = match command.kind {
            ProjectMutationKind::Add => {
                let normalized_path =
                    crate::domain::normalize_path_for_matching(&command.project_path);
                if normalized_path.is_empty() {
                    MutationOutcome {
                        ok: false,
                        message: "project_path cannot be empty".to_string(),
                    }
                } else {
                    let project_id = crate::domain::resolve_project_identity(&normalized_path)
                        .map(|identity| identity.project_id)
                        .unwrap_or_else(|| normalized_path.clone());
                    let workspace_id = default_workspace_id(&normalized_path);
                    let display_name = command
                        .display_name
                        .filter(|value| !value.trim().is_empty())
                        .unwrap_or_else(|| display_name(&normalized_path));

                    state.projects.insert(
                        normalized_path.clone(),
                        domain::ProjectSummary {
                            project_path: normalized_path,
                            project_id,
                            workspace_id,
                            display_name,
                            state: domain::SessionState::Idle,
                            state_changed_at: now_rfc3339(),
                            updated_at: now_rfc3339(),
                            representative_session_id: None,
                            latest_session_id: None,
                            session_count: 0,
                            active_count: 0,
                            has_session: false,
                        },
                    );

                    MutationOutcome {
                        ok: true,
                        message: "project added".to_string(),
                    }
                }
            }
            ProjectMutationKind::Remove => {
                let normalized_path =
                    crate::domain::normalize_path_for_matching(&command.project_path);
                state.projects.remove(&normalized_path);
                state.delegations.remove(&normalized_path);
                state
                    .sessions
                    .retain(|_, session| session.project_path != normalized_path);
                MutationOutcome {
                    ok: true,
                    message: "project removed".to_string(),
                }
            }
            ProjectMutationKind::Rename => {
                let normalized_path =
                    crate::domain::normalize_path_for_matching(&command.project_path);
                if let Some(project) = state.projects.get_mut(&normalized_path) {
                    if let Some(name) = command.display_name {
                        if !name.trim().is_empty() {
                            project.display_name = name;
                        }
                    }
                    project.updated_at = now_rfc3339();
                    MutationOutcome {
                        ok: true,
                        message: "project renamed".to_string(),
                    }
                } else {
                    MutationOutcome {
                        ok: false,
                        message: "project not found".to_string(),
                    }
                }
            }
        };

        if outcome.ok {
            self.bump_version_and_notify();
        }
        let snapshot = state.snapshot();
        drop(state);
        self.persist_snapshot(&snapshot)?;
        Ok(outcome)
    }

    pub fn mutate_delegation(
        &self,
        command: MutateDelegationCommand,
    ) -> Result<MutationOutcome, CoreRuntimeError> {
        let mut state = self.lock_state()?;
        let outcome = state.apply_delegation_mutation(command);
        self.bump_version_and_notify();
        let snapshot = state.snapshot();
        drop(state);
        self.persist_snapshot(&snapshot)?;
        Ok(outcome)
    }

    pub fn mutate_run(
        &self,
        command: domain::MutateRunCommand,
    ) -> Result<MutationOutcome, CoreRuntimeError> {
        let mut state = self.lock_state()?;
        let outcome = state.apply_run_mutation(command);
        self.bump_version_and_notify();
        let snapshot = state.snapshot();
        drop(state);
        self.persist_snapshot(&snapshot)?;
        Ok(outcome)
    }
}
