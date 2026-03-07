use std::sync::Arc;

use crate::domain::AppSnapshot;
use crate::reduce::ReducerState;
use crate::runtime_storage::StorageConfig;
use crate::storage::SnapshotStorage;

use super::domain::{RuntimeHealth, RuntimeObservation};
use super::ports::{RuntimeIngressPort, RuntimePortError, RuntimeSnapshotStore};

pub(crate) struct LiveRuntimeSnapshotStore {
    snapshot_storage: Arc<dyn SnapshotStorage>,
}

impl LiveRuntimeSnapshotStore {
    pub(crate) fn new(snapshot_storage: Arc<dyn SnapshotStorage>) -> Self {
        Self { snapshot_storage }
    }
}

impl RuntimeSnapshotStore for LiveRuntimeSnapshotStore {
    fn load_app_snapshot(&self) -> Result<AppSnapshot, RuntimePortError> {
        self.snapshot_storage
            .load_snapshot()
            .map_err(RuntimePortError::Storage)?
            .map_or_else(|| Ok(ReducerState::default().snapshot()), Ok)
    }

    fn save_app_snapshot(&self, snapshot: &AppSnapshot) -> Result<(), RuntimePortError> {
        self.snapshot_storage
            .save_snapshot(snapshot)
            .map_err(RuntimePortError::Storage)
    }
}

pub(crate) struct LiveRuntimeIngressPort {
    snapshot_storage: Arc<dyn SnapshotStorage>,
    app_storage: StorageConfig,
}

impl LiveRuntimeIngressPort {
    pub(crate) fn new(
        snapshot_storage: Arc<dyn SnapshotStorage>,
        app_storage: StorageConfig,
    ) -> Self {
        Self {
            snapshot_storage,
            app_storage,
        }
    }
}

impl RuntimeIngressPort for LiveRuntimeIngressPort {
    fn record_observation(&self, observation: RuntimeObservation) -> Result<(), RuntimePortError> {
        let _ = (&self.snapshot_storage, &self.app_storage, observation);
        Err(RuntimePortError::Unimplemented)
    }

    fn read_health(&self) -> Result<RuntimeHealth, RuntimePortError> {
        let snapshot_authoritative =
            crate::runtime_state::snapshot::runtime_health().unwrap_or(false);
        let hook_ingress_available = crate::runtime_state::snapshot::runtime_enabled();
        let diagnostics = match (hook_ingress_available, snapshot_authoritative) {
            (false, _) => vec!["Runtime snapshot health checks are disabled".to_string()],
            (true, false) => vec!["Runtime snapshot is unavailable".to_string()],
            (true, true) => Vec::new(),
        };

        Ok(RuntimeHealth {
            snapshot_authoritative,
            hook_ingress_available,
            diagnostics,
            checked_at: crate::clean::kernel::Timestamp(crate::domain::now_rfc3339()),
        })
    }
}
