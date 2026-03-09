use crate::contexts::runtime::domain::{RuntimeHealth, RuntimeObservation};
use crate::domain::AppSnapshot;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub(crate) enum RuntimePortError {
    #[error("{0}")]
    Storage(String),
    #[error("runtime shell is not implemented")]
    Unimplemented,
}

pub(crate) trait RuntimeSnapshotStore: Send + Sync {
    fn load_app_snapshot(&self) -> Result<AppSnapshot, RuntimePortError>;
    fn save_app_snapshot(&self, snapshot: &AppSnapshot) -> Result<(), RuntimePortError>;
}

pub(crate) trait RuntimeIngressPort: Send + Sync {
    fn record_observation(&self, observation: RuntimeObservation) -> Result<(), RuntimePortError>;
    fn read_health(&self) -> Result<RuntimeHealth, RuntimePortError>;
}
