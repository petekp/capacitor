use super::*;

impl CoreRuntime {
    fn ingest_hook_event_internal(
        &self,
        command: IngestHookEventCommand,
        gc_reference_time: Option<DateTime<Utc>>,
    ) -> Result<MutationOutcome, CoreRuntimeError> {
        let normalized = ingest::normalize_hook_event(command);
        self.commit(|state| {
            state.apply_hook_event_with_gc_reference_time(normalized, gc_reference_time)
        })
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
        self.commit(|state| state.apply_transcript_discovery(discovery))
    }

    pub fn unregister_shell(
        &self,
        command: domain::ShellUnregisterCommand,
    ) -> Result<MutationOutcome, CoreRuntimeError> {
        self.commit(|state| state.apply_shell_unregister(command))
    }

    /// Rollback variant of [`CoreRuntime::commit`] for run mutations gated by an
    /// external commit hook (e.g. a relay write). Locks once, snapshots the
    /// prior state, applies the run mutation, and on an accepted mutation runs
    /// `commit`. If `commit` fails, the reducer state is restored and an
    /// `ok:false` outcome is returned. Obeys the same bump-on-ok rule as
    /// [`CoreRuntime::commit`]: neither a rejected apply nor a failed `commit`
    /// advances the change version or wakes long-pollers.
    pub fn mutate_run_with_commit<F>(
        &self,
        command: domain::MutateRunCommand,
        commit: F,
    ) -> Result<MutationOutcome, CoreRuntimeError>
    where
        F: FnOnce() -> Result<(), String>,
    {
        self.try_commit(|state| {
            let previous_state = state.clone();
            let outcome = state.apply_run_mutation(command);

            if outcome.ok {
                if let Err(error) = commit() {
                    *state = previous_state;
                    return MutationOutcome {
                        ok: false,
                        message: format!("run mutation commit failed: {error}"),
                    };
                }
            }

            outcome
        })
    }

    pub fn checkpoint_decision_relay_for(
        &self,
        command: &domain::MutateRunCommand,
    ) -> Result<Option<domain::CheckpointDecisionRelay>, CoreRuntimeError> {
        let project_path = command.project_path.trim();
        let run_id = command.run_id.trim();
        let Some(checkpoint_id) = command
            .kind
            .checkpoint_id()
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
        self.commit(|state| state.apply_shell_signal(normalized))
    }

    /// Pure OS-liveness ingest. The caller (hud-hook sweep) owns the sysinfo
    /// probe and supplies the per-PID facts; this path only records them onto
    /// matching sessions via the pure reducer. It performs no OS calls itself.
    pub fn ingest_os_liveness(
        &self,
        command: IngestOsLivenessCommand,
    ) -> Result<MutationOutcome, CoreRuntimeError> {
        self.commit(|state| state.apply_os_liveness(command))
    }

    pub fn mutate_project(
        &self,
        command: MutateProjectCommand,
    ) -> Result<MutationOutcome, CoreRuntimeError> {
        self.commit(|state| state.apply_project_mutation(command))
    }

    pub fn mutate_delegation(
        &self,
        command: MutateDelegationCommand,
    ) -> Result<MutationOutcome, CoreRuntimeError> {
        self.commit(|state| state.apply_delegation_mutation(command))
    }

    pub fn mutate_run(
        &self,
        command: domain::MutateRunCommand,
    ) -> Result<MutationOutcome, CoreRuntimeError> {
        self.commit(|state| state.apply_run_mutation(command))
    }
}
