use crate::domain::AppSnapshot;
use crate::reduce::ReducerState;

#[must_use]
pub(crate) fn app_snapshot(state: &ReducerState) -> AppSnapshot {
    state.snapshot()
}
