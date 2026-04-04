use super::*;

impl CoreRuntime {
    pub fn run_gc_at(&self, now: DateTime<Utc>) -> Result<bool, CoreRuntimeError> {
        let mut state = self.lock_state()?;
        let changed = state.gc_stale_sessions_at(now);
        if changed {
            self.bump_version_and_notify();
            let snapshot = state.snapshot();
            drop(state);
            self.persist_snapshot(&snapshot)?;
            tracing::info!("gc_tick state_changed=true");
        } else {
            tracing::trace!("gc_tick state_changed=false");
        }
        Ok(changed)
    }
}

#[uniffi::export]
impl CoreRuntime {
    pub fn run_gc(&self) -> Result<bool, CoreRuntimeError> {
        self.run_gc_at(Utc::now())
    }
}
