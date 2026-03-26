//! Public API surface for the method runner subsystem.
//!
//! This module owns the structural seams for definition loading, event/state
//! modeling, storage layout, adapter contracts, execution, and resume flows.

pub mod adapter_config;
pub mod adapters;
pub mod checkpoint_bridge;
pub mod checkpoint_bridge_protocol;
pub mod checkpoint_manifest;
pub mod definition;
pub mod events;
pub mod executor;
pub mod handoff;
pub mod output;
pub mod prompt_builder_adapter;
pub mod resume;
pub mod run_status_reporter;
pub mod state;
pub mod storage;
pub mod worker_dispatch_adapter;
