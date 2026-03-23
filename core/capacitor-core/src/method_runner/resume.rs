//! Resume and reconciliation scaffolding for interrupted method runs.
//!
//! The full implementation will rebuild state from events, inspect the
//! filesystem, and reconcile in-flight work. Step 5 only establishes the
//! module surface for that two-phase process.

/// Structural entrypoint for resume flows.
#[derive(Debug, Default)]
pub struct ResumeCoordinator;

/// Placeholder type for event replay during resume.
#[derive(Debug, Default)]
pub struct ResumeReplay;

/// Placeholder type for reconciliation against on-disk artifacts.
#[derive(Debug, Default)]
pub struct ResumeReconciler;
