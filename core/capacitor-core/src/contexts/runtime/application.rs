use std::sync::Arc;

use super::domain::{RuntimeHealth, RuntimeObservation, RuntimeProjection};
use super::ports::{RuntimeIngressPort, RuntimePortError, RuntimeSnapshotStore};
use crate::domain::AppSnapshot;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub(crate) enum RuntimeServiceError {
    #[error(transparent)]
    Port(#[from] RuntimePortError),
    #[error("runtime shell is not implemented")]
    Unimplemented,
}

pub(crate) struct RuntimeService {
    snapshot_store: Arc<dyn RuntimeSnapshotStore>,
    ingress: Arc<dyn RuntimeIngressPort>,
}

impl RuntimeService {
    pub(crate) fn new(
        snapshot_store: Arc<dyn RuntimeSnapshotStore>,
        ingress: Arc<dyn RuntimeIngressPort>,
    ) -> Self {
        Self {
            snapshot_store,
            ingress,
        }
    }

    pub(crate) fn load_app_snapshot(&self) -> Result<AppSnapshot, RuntimeServiceError> {
        self.snapshot_store.load_app_snapshot().map_err(Into::into)
    }

    pub(crate) fn refresh_runtime_projection(
        &self,
    ) -> Result<RuntimeProjection, RuntimeServiceError> {
        Ok(self.load_app_snapshot()?.into())
    }

    pub(crate) fn record_runtime_observation(
        &self,
        observation: RuntimeObservation,
    ) -> Result<(), RuntimeServiceError> {
        self.ingress.record_observation(observation)?;
        self.snapshot_store
            .save_app_snapshot(&self.snapshot_store.load_app_snapshot()?)?;
        Ok(())
    }

    pub(crate) fn read_runtime_health(&self) -> Result<RuntimeHealth, RuntimeServiceError> {
        self.ingress.read_health().map_err(Into::into)
    }
}
