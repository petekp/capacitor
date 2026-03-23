//! Public API surface for the method runner subsystem.
//!
//! This module owns the structural seams for definition loading, event/state
//! modeling, storage layout, adapter contracts, execution, and resume flows.

pub mod adapters;
pub mod definition;
pub mod events;
pub mod executor;
pub mod handoff;
pub mod output;
pub mod resume;
pub mod state;
pub mod storage;
