use crate::observation::ObservationRecord;

pub trait ObservationJournalStore: Send + Sync {
    fn append(&self, observation: ObservationRecord) -> Result<(), String>;
    fn list(&self) -> Result<Vec<ObservationRecord>, String>;
}

#[derive(Default)]
pub struct InMemoryObservationJournalStore {
    observations: std::sync::Mutex<Vec<ObservationRecord>>,
}

impl ObservationJournalStore for InMemoryObservationJournalStore {
    fn append(&self, observation: ObservationRecord) -> Result<(), String> {
        let mut guard = self
            .observations
            .lock()
            .map_err(|_| "observation journal lock poisoned".to_string())?;
        guard.push(observation);
        Ok(())
    }

    fn list(&self) -> Result<Vec<ObservationRecord>, String> {
        let guard = self
            .observations
            .lock()
            .map_err(|_| "observation journal lock poisoned".to_string())?;
        Ok(guard.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::{InMemoryObservationJournalStore, ObservationJournalStore};
    use crate::domain::IngestShellSignalCommand;
    use crate::observation::{ObservationRecord, ObservationSourceKind};

    #[test]
    fn in_memory_observation_journal_store_round_trips_observations() {
        let store = InMemoryObservationJournalStore::default();
        let observation = ObservationRecord::from_shell_signal(IngestShellSignalCommand {
            pid: 42,
            cwd: "/repo".to_string(),
            tty: "/dev/ttys001".to_string(),
            parent_app: "ghostty".to_string(),
            tmux_session: None,
            tmux_client_tty: None,
            tmux_pane: None,
            tmux_panes: vec![],
            recorded_at: "2026-03-09T12:00:00Z".to_string(),
        });

        store.append(observation).expect("append observation");
        let observations = store.list().expect("list observations");

        assert_eq!(observations.len(), 1);
        assert_eq!(
            observations[0].source_kind,
            ObservationSourceKind::ShellSignal
        );
    }
}
