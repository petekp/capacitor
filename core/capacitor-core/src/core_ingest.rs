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

    /// Accept an idea mutation command.
    ///
    /// STUB: logs the command and persists a version bump, but does not yet
    /// mutate model state. Callers receive `ok: true` as acknowledgment.
    pub fn mutate_idea(
        &self,
        command: MutateIdeaCommand,
    ) -> Result<MutationOutcome, CoreRuntimeError> {
        let mut state = self.lock_state()?;
        state.events_ingested = state.events_ingested.saturating_add(1);
        let message = format!(
            "idea mutation accepted kind={:?} project_path={} idea_id={} (stub)",
            command.kind, command.project_path, command.idea_id
        );
        let outcome = MutationOutcome { ok: true, message };
        self.bump_version_and_notify();
        let snapshot = state.snapshot();
        drop(state);
        self.persist_snapshot(&snapshot)?;
        Ok(outcome)
    }

    /// Accept a worktree mutation command.
    ///
    /// STUB: logs the command and persists a version bump, but does not yet
    /// mutate model state. Callers receive `ok: true` as acknowledgment.
    pub fn mutate_worktree(
        &self,
        command: MutateWorktreeCommand,
    ) -> Result<MutationOutcome, CoreRuntimeError> {
        let mut state = self.lock_state()?;
        state.events_ingested = state.events_ingested.saturating_add(1);
        let message = format!(
            "worktree mutation accepted kind={:?} repo_path={} worktree_name={} force={} (stub)",
            command.kind, command.repo_path, command.worktree_name, command.force
        );
        let outcome = MutationOutcome { ok: true, message };
        self.bump_version_and_notify();
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

    pub fn capture_idea(
        &self,
        project_path: String,
        idea_text: String,
    ) -> Result<String, CoreRuntimeError> {
        runtime::ideas::capture_idea_with_storage(&self.app_storage, &project_path, &idea_text)
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn update_idea_status(
        &self,
        project_path: String,
        idea_id: String,
        new_status: String,
    ) -> Result<(), CoreRuntimeError> {
        runtime::ideas::update_idea_status_with_storage(
            &self.app_storage,
            &project_path,
            &idea_id,
            &new_status,
        )
        .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn update_idea_effort(
        &self,
        project_path: String,
        idea_id: String,
        new_effort: String,
    ) -> Result<(), CoreRuntimeError> {
        runtime::ideas::update_idea_effort_with_storage(
            &self.app_storage,
            &project_path,
            &idea_id,
            &new_effort,
        )
        .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn update_idea_triage(
        &self,
        project_path: String,
        idea_id: String,
        new_triage: String,
    ) -> Result<(), CoreRuntimeError> {
        runtime::ideas::update_idea_triage_with_storage(
            &self.app_storage,
            &project_path,
            &idea_id,
            &new_triage,
        )
        .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn update_idea_title(
        &self,
        project_path: String,
        idea_id: String,
        new_title: String,
    ) -> Result<(), CoreRuntimeError> {
        runtime::ideas::update_idea_title_with_storage(
            &self.app_storage,
            &project_path,
            &idea_id,
            &new_title,
        )
        .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn update_idea_description(
        &self,
        project_path: String,
        idea_id: String,
        new_description: String,
    ) -> Result<(), CoreRuntimeError> {
        runtime::ideas::update_idea_description_with_storage(
            &self.app_storage,
            &project_path,
            &idea_id,
            &new_description,
        )
        .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn save_ideas_order(
        &self,
        project_path: String,
        idea_ids: Vec<String>,
    ) -> Result<(), CoreRuntimeError> {
        runtime::ideas::save_ideas_order_with_storage(&self.app_storage, &project_path, idea_ids)
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }
}
