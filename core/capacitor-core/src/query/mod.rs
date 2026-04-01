use crate::domain::AppSnapshot;
use crate::reduce::ReducerState;

#[must_use]
pub fn app_snapshot(state: &mut ReducerState) -> AppSnapshot {
    state.snapshot()
}
