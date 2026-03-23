//! Exhaustive state-machine transition tests for every status enum in the
//! method runner. Each (from, to) pair is covered: legal transitions must
//! return `Ok`, illegal transitions must return `Err(TransitionError)` with
//! the correct `from` and `to` fields.

use capacitor_core::method_runner::state::*;

// =========================================================================
// Helpers
// =========================================================================

/// Assert a legal transition returns Ok with the expected next status.
fn assert_legal<S: std::fmt::Debug + Copy + PartialEq>(
    result: Result<S, TransitionError>,
    expected: S,
) {
    let actual = result.expect("expected legal transition to succeed");
    assert_eq!(actual, expected);
}

/// Assert an illegal transition returns Err and the error carries the right
/// (from, to) debug strings.
fn assert_illegal<S: std::fmt::Debug>(
    result: Result<S, TransitionError>,
    from_debug: &str,
    to_debug: &str,
) {
    let err = result.expect_err(&format!(
        "expected illegal transition {from_debug} -> {to_debug} to fail"
    ));
    assert_eq!(err.from, from_debug, "TransitionError.from mismatch");
    assert_eq!(err.to, to_debug, "TransitionError.to mismatch");
}

// =========================================================================
// RunStatus — 5 variants, 25 total pairs, 6 legal
// =========================================================================

// --- Legal transitions ---

#[test]
fn run_status_created_running_legal() {
    assert_legal(
        RunStatus::Created.transition_to(RunStatus::Running, "r1"),
        RunStatus::Running,
    );
}

#[test]
fn run_status_running_completed_legal() {
    assert_legal(
        RunStatus::Running.transition_to(RunStatus::Completed, "r1"),
        RunStatus::Completed,
    );
}

#[test]
fn run_status_running_failed_legal() {
    assert_legal(
        RunStatus::Running.transition_to(RunStatus::Failed, "r1"),
        RunStatus::Failed,
    );
}

#[test]
fn run_status_running_blocked_legal() {
    assert_legal(
        RunStatus::Running.transition_to(RunStatus::Blocked, "r1"),
        RunStatus::Blocked,
    );
}

#[test]
fn run_status_blocked_running_legal() {
    assert_legal(
        RunStatus::Blocked.transition_to(RunStatus::Running, "r1"),
        RunStatus::Running,
    );
}

#[test]
fn run_status_blocked_failed_legal() {
    assert_legal(
        RunStatus::Blocked.transition_to(RunStatus::Failed, "r1"),
        RunStatus::Failed,
    );
}

// --- Illegal transitions ---

#[test]
fn run_status_created_created_illegal() {
    assert_illegal(
        RunStatus::Created.transition_to(RunStatus::Created, "r1"),
        "Created",
        "Created",
    );
}

#[test]
fn run_status_created_completed_illegal() {
    assert_illegal(
        RunStatus::Created.transition_to(RunStatus::Completed, "r1"),
        "Created",
        "Completed",
    );
}

#[test]
fn run_status_created_failed_illegal() {
    assert_illegal(
        RunStatus::Created.transition_to(RunStatus::Failed, "r1"),
        "Created",
        "Failed",
    );
}

#[test]
fn run_status_created_blocked_illegal() {
    assert_illegal(
        RunStatus::Created.transition_to(RunStatus::Blocked, "r1"),
        "Created",
        "Blocked",
    );
}

#[test]
fn run_status_running_created_illegal() {
    assert_illegal(
        RunStatus::Running.transition_to(RunStatus::Created, "r1"),
        "Running",
        "Created",
    );
}

#[test]
fn run_status_running_running_illegal() {
    assert_illegal(
        RunStatus::Running.transition_to(RunStatus::Running, "r1"),
        "Running",
        "Running",
    );
}

#[test]
fn run_status_completed_created_illegal() {
    assert_illegal(
        RunStatus::Completed.transition_to(RunStatus::Created, "r1"),
        "Completed",
        "Created",
    );
}

#[test]
fn run_status_completed_running_illegal() {
    assert_illegal(
        RunStatus::Completed.transition_to(RunStatus::Running, "r1"),
        "Completed",
        "Running",
    );
}

#[test]
fn run_status_completed_completed_illegal() {
    assert_illegal(
        RunStatus::Completed.transition_to(RunStatus::Completed, "r1"),
        "Completed",
        "Completed",
    );
}

#[test]
fn run_status_completed_failed_illegal() {
    assert_illegal(
        RunStatus::Completed.transition_to(RunStatus::Failed, "r1"),
        "Completed",
        "Failed",
    );
}

#[test]
fn run_status_completed_blocked_illegal() {
    assert_illegal(
        RunStatus::Completed.transition_to(RunStatus::Blocked, "r1"),
        "Completed",
        "Blocked",
    );
}

#[test]
fn run_status_failed_created_illegal() {
    assert_illegal(
        RunStatus::Failed.transition_to(RunStatus::Created, "r1"),
        "Failed",
        "Created",
    );
}

#[test]
fn run_status_failed_running_illegal() {
    assert_illegal(
        RunStatus::Failed.transition_to(RunStatus::Running, "r1"),
        "Failed",
        "Running",
    );
}

#[test]
fn run_status_failed_completed_illegal() {
    assert_illegal(
        RunStatus::Failed.transition_to(RunStatus::Completed, "r1"),
        "Failed",
        "Completed",
    );
}

#[test]
fn run_status_failed_failed_illegal() {
    assert_illegal(
        RunStatus::Failed.transition_to(RunStatus::Failed, "r1"),
        "Failed",
        "Failed",
    );
}

#[test]
fn run_status_failed_blocked_illegal() {
    assert_illegal(
        RunStatus::Failed.transition_to(RunStatus::Blocked, "r1"),
        "Failed",
        "Blocked",
    );
}

#[test]
fn run_status_blocked_created_illegal() {
    assert_illegal(
        RunStatus::Blocked.transition_to(RunStatus::Created, "r1"),
        "Blocked",
        "Created",
    );
}

#[test]
fn run_status_blocked_completed_illegal() {
    assert_illegal(
        RunStatus::Blocked.transition_to(RunStatus::Completed, "r1"),
        "Blocked",
        "Completed",
    );
}

#[test]
fn run_status_blocked_blocked_illegal() {
    assert_illegal(
        RunStatus::Blocked.transition_to(RunStatus::Blocked, "r1"),
        "Blocked",
        "Blocked",
    );
}

// =========================================================================
// PhaseStatus — 6 variants, 36 total pairs, 7 legal
// =========================================================================

// --- Legal transitions ---

#[test]
fn phase_status_pending_running_legal() {
    assert_legal(
        PhaseStatus::Pending.transition_to(PhaseStatus::Running, "p1"),
        PhaseStatus::Running,
    );
}

#[test]
fn phase_status_running_completed_legal() {
    assert_legal(
        PhaseStatus::Running.transition_to(PhaseStatus::Completed, "p1"),
        PhaseStatus::Completed,
    );
}

#[test]
fn phase_status_running_failed_legal() {
    assert_legal(
        PhaseStatus::Running.transition_to(PhaseStatus::Failed, "p1"),
        PhaseStatus::Failed,
    );
}

#[test]
fn phase_status_running_blocked_legal() {
    assert_legal(
        PhaseStatus::Running.transition_to(PhaseStatus::Blocked, "p1"),
        PhaseStatus::Blocked,
    );
}

#[test]
fn phase_status_running_skipped_legal() {
    assert_legal(
        PhaseStatus::Running.transition_to(PhaseStatus::Skipped, "p1"),
        PhaseStatus::Skipped,
    );
}

#[test]
fn phase_status_blocked_running_legal() {
    assert_legal(
        PhaseStatus::Blocked.transition_to(PhaseStatus::Running, "p1"),
        PhaseStatus::Running,
    );
}

#[test]
fn phase_status_blocked_failed_legal() {
    assert_legal(
        PhaseStatus::Blocked.transition_to(PhaseStatus::Failed, "p1"),
        PhaseStatus::Failed,
    );
}

// --- Illegal transitions ---

#[test]
fn phase_status_pending_pending_illegal() {
    assert_illegal(
        PhaseStatus::Pending.transition_to(PhaseStatus::Pending, "p1"),
        "Pending",
        "Pending",
    );
}

#[test]
fn phase_status_pending_completed_illegal() {
    assert_illegal(
        PhaseStatus::Pending.transition_to(PhaseStatus::Completed, "p1"),
        "Pending",
        "Completed",
    );
}

#[test]
fn phase_status_pending_failed_illegal() {
    assert_illegal(
        PhaseStatus::Pending.transition_to(PhaseStatus::Failed, "p1"),
        "Pending",
        "Failed",
    );
}

#[test]
fn phase_status_pending_blocked_illegal() {
    assert_illegal(
        PhaseStatus::Pending.transition_to(PhaseStatus::Blocked, "p1"),
        "Pending",
        "Blocked",
    );
}

#[test]
fn phase_status_pending_skipped_illegal() {
    assert_illegal(
        PhaseStatus::Pending.transition_to(PhaseStatus::Skipped, "p1"),
        "Pending",
        "Skipped",
    );
}

#[test]
fn phase_status_running_pending_illegal() {
    assert_illegal(
        PhaseStatus::Running.transition_to(PhaseStatus::Pending, "p1"),
        "Running",
        "Pending",
    );
}

#[test]
fn phase_status_running_running_idempotent() {
    // Running->Running is legal (idempotent) to support resume restart.
    let result = PhaseStatus::Running.transition_to(PhaseStatus::Running, "p1");
    assert!(
        result.is_ok(),
        "Running->Running should be legal for phases"
    );
    assert_eq!(result.unwrap(), PhaseStatus::Running);
}

#[test]
fn phase_status_completed_pending_illegal() {
    assert_illegal(
        PhaseStatus::Completed.transition_to(PhaseStatus::Pending, "p1"),
        "Completed",
        "Pending",
    );
}

#[test]
fn phase_status_completed_running_illegal() {
    assert_illegal(
        PhaseStatus::Completed.transition_to(PhaseStatus::Running, "p1"),
        "Completed",
        "Running",
    );
}

#[test]
fn phase_status_completed_completed_illegal() {
    assert_illegal(
        PhaseStatus::Completed.transition_to(PhaseStatus::Completed, "p1"),
        "Completed",
        "Completed",
    );
}

#[test]
fn phase_status_completed_failed_illegal() {
    assert_illegal(
        PhaseStatus::Completed.transition_to(PhaseStatus::Failed, "p1"),
        "Completed",
        "Failed",
    );
}

#[test]
fn phase_status_completed_blocked_illegal() {
    assert_illegal(
        PhaseStatus::Completed.transition_to(PhaseStatus::Blocked, "p1"),
        "Completed",
        "Blocked",
    );
}

#[test]
fn phase_status_completed_skipped_illegal() {
    assert_illegal(
        PhaseStatus::Completed.transition_to(PhaseStatus::Skipped, "p1"),
        "Completed",
        "Skipped",
    );
}

#[test]
fn phase_status_failed_pending_illegal() {
    assert_illegal(
        PhaseStatus::Failed.transition_to(PhaseStatus::Pending, "p1"),
        "Failed",
        "Pending",
    );
}

#[test]
fn phase_status_failed_running_illegal() {
    assert_illegal(
        PhaseStatus::Failed.transition_to(PhaseStatus::Running, "p1"),
        "Failed",
        "Running",
    );
}

#[test]
fn phase_status_failed_completed_illegal() {
    assert_illegal(
        PhaseStatus::Failed.transition_to(PhaseStatus::Completed, "p1"),
        "Failed",
        "Completed",
    );
}

#[test]
fn phase_status_failed_failed_illegal() {
    assert_illegal(
        PhaseStatus::Failed.transition_to(PhaseStatus::Failed, "p1"),
        "Failed",
        "Failed",
    );
}

#[test]
fn phase_status_failed_blocked_illegal() {
    assert_illegal(
        PhaseStatus::Failed.transition_to(PhaseStatus::Blocked, "p1"),
        "Failed",
        "Blocked",
    );
}

#[test]
fn phase_status_failed_skipped_illegal() {
    assert_illegal(
        PhaseStatus::Failed.transition_to(PhaseStatus::Skipped, "p1"),
        "Failed",
        "Skipped",
    );
}

#[test]
fn phase_status_blocked_pending_illegal() {
    assert_illegal(
        PhaseStatus::Blocked.transition_to(PhaseStatus::Pending, "p1"),
        "Blocked",
        "Pending",
    );
}

#[test]
fn phase_status_blocked_completed_illegal() {
    assert_illegal(
        PhaseStatus::Blocked.transition_to(PhaseStatus::Completed, "p1"),
        "Blocked",
        "Completed",
    );
}

#[test]
fn phase_status_blocked_blocked_illegal() {
    assert_illegal(
        PhaseStatus::Blocked.transition_to(PhaseStatus::Blocked, "p1"),
        "Blocked",
        "Blocked",
    );
}

#[test]
fn phase_status_blocked_skipped_illegal() {
    assert_illegal(
        PhaseStatus::Blocked.transition_to(PhaseStatus::Skipped, "p1"),
        "Blocked",
        "Skipped",
    );
}

#[test]
fn phase_status_skipped_pending_illegal() {
    assert_illegal(
        PhaseStatus::Skipped.transition_to(PhaseStatus::Pending, "p1"),
        "Skipped",
        "Pending",
    );
}

#[test]
fn phase_status_skipped_running_illegal() {
    assert_illegal(
        PhaseStatus::Skipped.transition_to(PhaseStatus::Running, "p1"),
        "Skipped",
        "Running",
    );
}

#[test]
fn phase_status_skipped_completed_illegal() {
    assert_illegal(
        PhaseStatus::Skipped.transition_to(PhaseStatus::Completed, "p1"),
        "Skipped",
        "Completed",
    );
}

#[test]
fn phase_status_skipped_failed_illegal() {
    assert_illegal(
        PhaseStatus::Skipped.transition_to(PhaseStatus::Failed, "p1"),
        "Skipped",
        "Failed",
    );
}

#[test]
fn phase_status_skipped_blocked_illegal() {
    assert_illegal(
        PhaseStatus::Skipped.transition_to(PhaseStatus::Blocked, "p1"),
        "Skipped",
        "Blocked",
    );
}

#[test]
fn phase_status_skipped_skipped_illegal() {
    assert_illegal(
        PhaseStatus::Skipped.transition_to(PhaseStatus::Skipped, "p1"),
        "Skipped",
        "Skipped",
    );
}

// =========================================================================
// StepStatus — 5 variants, 25 total pairs, 6 legal
// =========================================================================

// --- Legal transitions ---

#[test]
fn step_status_pending_running_legal() {
    assert_legal(
        StepStatus::Pending.transition_to(StepStatus::Running, "s1"),
        StepStatus::Running,
    );
}

#[test]
fn step_status_running_completed_legal() {
    assert_legal(
        StepStatus::Running.transition_to(StepStatus::Completed, "s1"),
        StepStatus::Completed,
    );
}

#[test]
fn step_status_running_failed_legal() {
    assert_legal(
        StepStatus::Running.transition_to(StepStatus::Failed, "s1"),
        StepStatus::Failed,
    );
}

#[test]
fn step_status_running_blocked_legal() {
    assert_legal(
        StepStatus::Running.transition_to(StepStatus::Blocked, "s1"),
        StepStatus::Blocked,
    );
}

#[test]
fn step_status_blocked_running_legal() {
    assert_legal(
        StepStatus::Blocked.transition_to(StepStatus::Running, "s1"),
        StepStatus::Running,
    );
}

#[test]
fn step_status_blocked_failed_legal() {
    assert_legal(
        StepStatus::Blocked.transition_to(StepStatus::Failed, "s1"),
        StepStatus::Failed,
    );
}

// --- Illegal transitions ---

#[test]
fn step_status_pending_pending_illegal() {
    assert_illegal(
        StepStatus::Pending.transition_to(StepStatus::Pending, "s1"),
        "Pending",
        "Pending",
    );
}

#[test]
fn step_status_pending_completed_illegal() {
    assert_illegal(
        StepStatus::Pending.transition_to(StepStatus::Completed, "s1"),
        "Pending",
        "Completed",
    );
}

#[test]
fn step_status_pending_failed_illegal() {
    assert_illegal(
        StepStatus::Pending.transition_to(StepStatus::Failed, "s1"),
        "Pending",
        "Failed",
    );
}

#[test]
fn step_status_pending_blocked_illegal() {
    assert_illegal(
        StepStatus::Pending.transition_to(StepStatus::Blocked, "s1"),
        "Pending",
        "Blocked",
    );
}

#[test]
fn step_status_running_pending_illegal() {
    assert_illegal(
        StepStatus::Running.transition_to(StepStatus::Pending, "s1"),
        "Running",
        "Pending",
    );
}

#[test]
fn step_status_running_running_idempotent() {
    // Running->Running is legal (idempotent) to support resume restart.
    let result = StepStatus::Running.transition_to(StepStatus::Running, "s1");
    assert!(result.is_ok(), "Running->Running should be legal for steps");
    assert_eq!(result.unwrap(), StepStatus::Running);
}

#[test]
fn step_status_completed_pending_illegal() {
    assert_illegal(
        StepStatus::Completed.transition_to(StepStatus::Pending, "s1"),
        "Completed",
        "Pending",
    );
}

#[test]
fn step_status_completed_running_illegal() {
    assert_illegal(
        StepStatus::Completed.transition_to(StepStatus::Running, "s1"),
        "Completed",
        "Running",
    );
}

#[test]
fn step_status_completed_completed_illegal() {
    assert_illegal(
        StepStatus::Completed.transition_to(StepStatus::Completed, "s1"),
        "Completed",
        "Completed",
    );
}

#[test]
fn step_status_completed_failed_illegal() {
    assert_illegal(
        StepStatus::Completed.transition_to(StepStatus::Failed, "s1"),
        "Completed",
        "Failed",
    );
}

#[test]
fn step_status_completed_blocked_illegal() {
    assert_illegal(
        StepStatus::Completed.transition_to(StepStatus::Blocked, "s1"),
        "Completed",
        "Blocked",
    );
}

#[test]
fn step_status_failed_pending_illegal() {
    assert_illegal(
        StepStatus::Failed.transition_to(StepStatus::Pending, "s1"),
        "Failed",
        "Pending",
    );
}

#[test]
fn step_status_failed_running_illegal() {
    assert_illegal(
        StepStatus::Failed.transition_to(StepStatus::Running, "s1"),
        "Failed",
        "Running",
    );
}

#[test]
fn step_status_failed_completed_illegal() {
    assert_illegal(
        StepStatus::Failed.transition_to(StepStatus::Completed, "s1"),
        "Failed",
        "Completed",
    );
}

#[test]
fn step_status_failed_failed_illegal() {
    assert_illegal(
        StepStatus::Failed.transition_to(StepStatus::Failed, "s1"),
        "Failed",
        "Failed",
    );
}

#[test]
fn step_status_failed_blocked_illegal() {
    assert_illegal(
        StepStatus::Failed.transition_to(StepStatus::Blocked, "s1"),
        "Failed",
        "Blocked",
    );
}

#[test]
fn step_status_blocked_pending_illegal() {
    assert_illegal(
        StepStatus::Blocked.transition_to(StepStatus::Pending, "s1"),
        "Blocked",
        "Pending",
    );
}

#[test]
fn step_status_blocked_completed_illegal() {
    assert_illegal(
        StepStatus::Blocked.transition_to(StepStatus::Completed, "s1"),
        "Blocked",
        "Completed",
    );
}

#[test]
fn step_status_blocked_blocked_illegal() {
    assert_illegal(
        StepStatus::Blocked.transition_to(StepStatus::Blocked, "s1"),
        "Blocked",
        "Blocked",
    );
}

// =========================================================================
// AttemptStatus — 7 variants, 49 total pairs, 8 legal
// =========================================================================

// --- Legal transitions ---

#[test]
fn attempt_status_created_dispatching_legal() {
    assert_legal(
        AttemptStatus::Created.transition_to(AttemptStatus::Dispatching, "a1"),
        AttemptStatus::Dispatching,
    );
}

#[test]
fn attempt_status_dispatching_running_legal() {
    assert_legal(
        AttemptStatus::Dispatching.transition_to(AttemptStatus::Running, "a1"),
        AttemptStatus::Running,
    );
}

#[test]
fn attempt_status_running_handoff_received_legal() {
    assert_legal(
        AttemptStatus::Running.transition_to(AttemptStatus::HandoffReceived, "a1"),
        AttemptStatus::HandoffReceived,
    );
}

#[test]
fn attempt_status_running_failed_legal() {
    assert_legal(
        AttemptStatus::Running.transition_to(AttemptStatus::Failed, "a1"),
        AttemptStatus::Failed,
    );
}

#[test]
fn attempt_status_handoff_received_output_bound_legal() {
    assert_legal(
        AttemptStatus::HandoffReceived.transition_to(AttemptStatus::OutputBound, "a1"),
        AttemptStatus::OutputBound,
    );
}

#[test]
fn attempt_status_handoff_received_failed_legal() {
    assert_legal(
        AttemptStatus::HandoffReceived.transition_to(AttemptStatus::Failed, "a1"),
        AttemptStatus::Failed,
    );
}

#[test]
fn attempt_status_output_bound_completed_legal() {
    assert_legal(
        AttemptStatus::OutputBound.transition_to(AttemptStatus::Completed, "a1"),
        AttemptStatus::Completed,
    );
}

#[test]
fn attempt_status_output_bound_failed_legal() {
    assert_legal(
        AttemptStatus::OutputBound.transition_to(AttemptStatus::Failed, "a1"),
        AttemptStatus::Failed,
    );
}

// --- Illegal transitions ---

#[test]
fn attempt_status_created_created_illegal() {
    assert_illegal(
        AttemptStatus::Created.transition_to(AttemptStatus::Created, "a1"),
        "Created",
        "Created",
    );
}

#[test]
fn attempt_status_created_running_illegal() {
    assert_illegal(
        AttemptStatus::Created.transition_to(AttemptStatus::Running, "a1"),
        "Created",
        "Running",
    );
}

#[test]
fn attempt_status_created_handoff_received_illegal() {
    assert_illegal(
        AttemptStatus::Created.transition_to(AttemptStatus::HandoffReceived, "a1"),
        "Created",
        "HandoffReceived",
    );
}

#[test]
fn attempt_status_created_output_bound_legal() {
    // Legal for synthesis/interactive paths: no worker dispatch, direct output binding
    assert_legal(
        AttemptStatus::Created.transition_to(AttemptStatus::OutputBound, "a1"),
        AttemptStatus::OutputBound,
    );
}

#[test]
fn attempt_status_created_completed_illegal() {
    assert_illegal(
        AttemptStatus::Created.transition_to(AttemptStatus::Completed, "a1"),
        "Created",
        "Completed",
    );
}

#[test]
fn attempt_status_created_failed_legal() {
    // Created → Failed is legal: adapter error before any dispatch
    assert_legal(
        AttemptStatus::Created.transition_to(AttemptStatus::Failed, "a1"),
        AttemptStatus::Failed,
    );
}

#[test]
fn attempt_status_dispatching_created_illegal() {
    assert_illegal(
        AttemptStatus::Dispatching.transition_to(AttemptStatus::Created, "a1"),
        "Dispatching",
        "Created",
    );
}

#[test]
fn attempt_status_dispatching_dispatching_illegal() {
    assert_illegal(
        AttemptStatus::Dispatching.transition_to(AttemptStatus::Dispatching, "a1"),
        "Dispatching",
        "Dispatching",
    );
}

#[test]
fn attempt_status_dispatching_handoff_received_illegal() {
    assert_illegal(
        AttemptStatus::Dispatching.transition_to(AttemptStatus::HandoffReceived, "a1"),
        "Dispatching",
        "HandoffReceived",
    );
}

#[test]
fn attempt_status_dispatching_output_bound_illegal() {
    assert_illegal(
        AttemptStatus::Dispatching.transition_to(AttemptStatus::OutputBound, "a1"),
        "Dispatching",
        "OutputBound",
    );
}

#[test]
fn attempt_status_dispatching_completed_illegal() {
    assert_illegal(
        AttemptStatus::Dispatching.transition_to(AttemptStatus::Completed, "a1"),
        "Dispatching",
        "Completed",
    );
}

#[test]
fn attempt_status_dispatching_failed_legal() {
    // Dispatching → Failed is legal: all workers failed during dispatch phase
    assert_legal(
        AttemptStatus::Dispatching.transition_to(AttemptStatus::Failed, "a1"),
        AttemptStatus::Failed,
    );
}

#[test]
fn attempt_status_running_created_illegal() {
    assert_illegal(
        AttemptStatus::Running.transition_to(AttemptStatus::Created, "a1"),
        "Running",
        "Created",
    );
}

#[test]
fn attempt_status_running_dispatching_illegal() {
    assert_illegal(
        AttemptStatus::Running.transition_to(AttemptStatus::Dispatching, "a1"),
        "Running",
        "Dispatching",
    );
}

#[test]
fn attempt_status_running_running_illegal() {
    assert_illegal(
        AttemptStatus::Running.transition_to(AttemptStatus::Running, "a1"),
        "Running",
        "Running",
    );
}

#[test]
fn attempt_status_running_output_bound_illegal() {
    assert_illegal(
        AttemptStatus::Running.transition_to(AttemptStatus::OutputBound, "a1"),
        "Running",
        "OutputBound",
    );
}

#[test]
fn attempt_status_running_completed_illegal() {
    assert_illegal(
        AttemptStatus::Running.transition_to(AttemptStatus::Completed, "a1"),
        "Running",
        "Completed",
    );
}

#[test]
fn attempt_status_handoff_received_created_illegal() {
    assert_illegal(
        AttemptStatus::HandoffReceived.transition_to(AttemptStatus::Created, "a1"),
        "HandoffReceived",
        "Created",
    );
}

#[test]
fn attempt_status_handoff_received_dispatching_illegal() {
    assert_illegal(
        AttemptStatus::HandoffReceived.transition_to(AttemptStatus::Dispatching, "a1"),
        "HandoffReceived",
        "Dispatching",
    );
}

#[test]
fn attempt_status_handoff_received_running_illegal() {
    assert_illegal(
        AttemptStatus::HandoffReceived.transition_to(AttemptStatus::Running, "a1"),
        "HandoffReceived",
        "Running",
    );
}

#[test]
fn attempt_status_handoff_received_handoff_received_illegal() {
    assert_illegal(
        AttemptStatus::HandoffReceived.transition_to(AttemptStatus::HandoffReceived, "a1"),
        "HandoffReceived",
        "HandoffReceived",
    );
}

#[test]
fn attempt_status_handoff_received_completed_illegal() {
    assert_illegal(
        AttemptStatus::HandoffReceived.transition_to(AttemptStatus::Completed, "a1"),
        "HandoffReceived",
        "Completed",
    );
}

#[test]
fn attempt_status_output_bound_created_illegal() {
    assert_illegal(
        AttemptStatus::OutputBound.transition_to(AttemptStatus::Created, "a1"),
        "OutputBound",
        "Created",
    );
}

#[test]
fn attempt_status_output_bound_dispatching_illegal() {
    assert_illegal(
        AttemptStatus::OutputBound.transition_to(AttemptStatus::Dispatching, "a1"),
        "OutputBound",
        "Dispatching",
    );
}

#[test]
fn attempt_status_output_bound_running_illegal() {
    assert_illegal(
        AttemptStatus::OutputBound.transition_to(AttemptStatus::Running, "a1"),
        "OutputBound",
        "Running",
    );
}

#[test]
fn attempt_status_output_bound_handoff_received_illegal() {
    assert_illegal(
        AttemptStatus::OutputBound.transition_to(AttemptStatus::HandoffReceived, "a1"),
        "OutputBound",
        "HandoffReceived",
    );
}

#[test]
fn attempt_status_output_bound_output_bound_illegal() {
    assert_illegal(
        AttemptStatus::OutputBound.transition_to(AttemptStatus::OutputBound, "a1"),
        "OutputBound",
        "OutputBound",
    );
}

#[test]
fn attempt_status_completed_created_illegal() {
    assert_illegal(
        AttemptStatus::Completed.transition_to(AttemptStatus::Created, "a1"),
        "Completed",
        "Created",
    );
}

#[test]
fn attempt_status_completed_dispatching_illegal() {
    assert_illegal(
        AttemptStatus::Completed.transition_to(AttemptStatus::Dispatching, "a1"),
        "Completed",
        "Dispatching",
    );
}

#[test]
fn attempt_status_completed_running_illegal() {
    assert_illegal(
        AttemptStatus::Completed.transition_to(AttemptStatus::Running, "a1"),
        "Completed",
        "Running",
    );
}

#[test]
fn attempt_status_completed_handoff_received_illegal() {
    assert_illegal(
        AttemptStatus::Completed.transition_to(AttemptStatus::HandoffReceived, "a1"),
        "Completed",
        "HandoffReceived",
    );
}

#[test]
fn attempt_status_completed_output_bound_illegal() {
    assert_illegal(
        AttemptStatus::Completed.transition_to(AttemptStatus::OutputBound, "a1"),
        "Completed",
        "OutputBound",
    );
}

#[test]
fn attempt_status_completed_completed_illegal() {
    assert_illegal(
        AttemptStatus::Completed.transition_to(AttemptStatus::Completed, "a1"),
        "Completed",
        "Completed",
    );
}

#[test]
fn attempt_status_completed_failed_illegal() {
    assert_illegal(
        AttemptStatus::Completed.transition_to(AttemptStatus::Failed, "a1"),
        "Completed",
        "Failed",
    );
}

#[test]
fn attempt_status_failed_created_illegal() {
    assert_illegal(
        AttemptStatus::Failed.transition_to(AttemptStatus::Created, "a1"),
        "Failed",
        "Created",
    );
}

#[test]
fn attempt_status_failed_dispatching_illegal() {
    assert_illegal(
        AttemptStatus::Failed.transition_to(AttemptStatus::Dispatching, "a1"),
        "Failed",
        "Dispatching",
    );
}

#[test]
fn attempt_status_failed_running_illegal() {
    assert_illegal(
        AttemptStatus::Failed.transition_to(AttemptStatus::Running, "a1"),
        "Failed",
        "Running",
    );
}

#[test]
fn attempt_status_failed_handoff_received_illegal() {
    assert_illegal(
        AttemptStatus::Failed.transition_to(AttemptStatus::HandoffReceived, "a1"),
        "Failed",
        "HandoffReceived",
    );
}

#[test]
fn attempt_status_failed_output_bound_illegal() {
    assert_illegal(
        AttemptStatus::Failed.transition_to(AttemptStatus::OutputBound, "a1"),
        "Failed",
        "OutputBound",
    );
}

#[test]
fn attempt_status_failed_completed_illegal() {
    assert_illegal(
        AttemptStatus::Failed.transition_to(AttemptStatus::Completed, "a1"),
        "Failed",
        "Completed",
    );
}

#[test]
fn attempt_status_failed_failed_illegal() {
    assert_illegal(
        AttemptStatus::Failed.transition_to(AttemptStatus::Failed, "a1"),
        "Failed",
        "Failed",
    );
}

// =========================================================================
// WorkerStatus — 5 variants, 25 total pairs, 4 legal
// =========================================================================

// --- Legal transitions ---

#[test]
fn worker_status_pending_dispatched_legal() {
    assert_legal(
        WorkerStatus::Pending.transition_to(WorkerStatus::Dispatched, "w1"),
        WorkerStatus::Dispatched,
    );
}

#[test]
fn worker_status_dispatched_running_legal() {
    assert_legal(
        WorkerStatus::Dispatched.transition_to(WorkerStatus::Running, "w1"),
        WorkerStatus::Running,
    );
}

#[test]
fn worker_status_running_completed_legal() {
    assert_legal(
        WorkerStatus::Running.transition_to(WorkerStatus::Completed, "w1"),
        WorkerStatus::Completed,
    );
}

#[test]
fn worker_status_running_failed_legal() {
    assert_legal(
        WorkerStatus::Running.transition_to(WorkerStatus::Failed, "w1"),
        WorkerStatus::Failed,
    );
}

// --- Illegal transitions ---

#[test]
fn worker_status_pending_pending_illegal() {
    assert_illegal(
        WorkerStatus::Pending.transition_to(WorkerStatus::Pending, "w1"),
        "Pending",
        "Pending",
    );
}

#[test]
fn worker_status_pending_running_illegal() {
    assert_illegal(
        WorkerStatus::Pending.transition_to(WorkerStatus::Running, "w1"),
        "Pending",
        "Running",
    );
}

#[test]
fn worker_status_pending_completed_illegal() {
    assert_illegal(
        WorkerStatus::Pending.transition_to(WorkerStatus::Completed, "w1"),
        "Pending",
        "Completed",
    );
}

#[test]
fn worker_status_pending_failed_illegal() {
    assert_illegal(
        WorkerStatus::Pending.transition_to(WorkerStatus::Failed, "w1"),
        "Pending",
        "Failed",
    );
}

#[test]
fn worker_status_dispatched_pending_illegal() {
    assert_illegal(
        WorkerStatus::Dispatched.transition_to(WorkerStatus::Pending, "w1"),
        "Dispatched",
        "Pending",
    );
}

#[test]
fn worker_status_dispatched_dispatched_illegal() {
    assert_illegal(
        WorkerStatus::Dispatched.transition_to(WorkerStatus::Dispatched, "w1"),
        "Dispatched",
        "Dispatched",
    );
}

#[test]
fn worker_status_dispatched_completed_illegal() {
    assert_illegal(
        WorkerStatus::Dispatched.transition_to(WorkerStatus::Completed, "w1"),
        "Dispatched",
        "Completed",
    );
}

#[test]
fn worker_status_dispatched_failed_illegal() {
    assert_illegal(
        WorkerStatus::Dispatched.transition_to(WorkerStatus::Failed, "w1"),
        "Dispatched",
        "Failed",
    );
}

#[test]
fn worker_status_running_pending_illegal() {
    assert_illegal(
        WorkerStatus::Running.transition_to(WorkerStatus::Pending, "w1"),
        "Running",
        "Pending",
    );
}

#[test]
fn worker_status_running_dispatched_illegal() {
    assert_illegal(
        WorkerStatus::Running.transition_to(WorkerStatus::Dispatched, "w1"),
        "Running",
        "Dispatched",
    );
}

#[test]
fn worker_status_running_running_illegal() {
    assert_illegal(
        WorkerStatus::Running.transition_to(WorkerStatus::Running, "w1"),
        "Running",
        "Running",
    );
}

#[test]
fn worker_status_completed_pending_illegal() {
    assert_illegal(
        WorkerStatus::Completed.transition_to(WorkerStatus::Pending, "w1"),
        "Completed",
        "Pending",
    );
}

#[test]
fn worker_status_completed_dispatched_illegal() {
    assert_illegal(
        WorkerStatus::Completed.transition_to(WorkerStatus::Dispatched, "w1"),
        "Completed",
        "Dispatched",
    );
}

#[test]
fn worker_status_completed_running_illegal() {
    assert_illegal(
        WorkerStatus::Completed.transition_to(WorkerStatus::Running, "w1"),
        "Completed",
        "Running",
    );
}

#[test]
fn worker_status_completed_completed_illegal() {
    assert_illegal(
        WorkerStatus::Completed.transition_to(WorkerStatus::Completed, "w1"),
        "Completed",
        "Completed",
    );
}

#[test]
fn worker_status_completed_failed_illegal() {
    assert_illegal(
        WorkerStatus::Completed.transition_to(WorkerStatus::Failed, "w1"),
        "Completed",
        "Failed",
    );
}

#[test]
fn worker_status_failed_pending_illegal() {
    assert_illegal(
        WorkerStatus::Failed.transition_to(WorkerStatus::Pending, "w1"),
        "Failed",
        "Pending",
    );
}

#[test]
fn worker_status_failed_dispatched_illegal() {
    assert_illegal(
        WorkerStatus::Failed.transition_to(WorkerStatus::Dispatched, "w1"),
        "Failed",
        "Dispatched",
    );
}

#[test]
fn worker_status_failed_running_illegal() {
    assert_illegal(
        WorkerStatus::Failed.transition_to(WorkerStatus::Running, "w1"),
        "Failed",
        "Running",
    );
}

#[test]
fn worker_status_failed_completed_illegal() {
    assert_illegal(
        WorkerStatus::Failed.transition_to(WorkerStatus::Completed, "w1"),
        "Failed",
        "Completed",
    );
}

#[test]
fn worker_status_failed_failed_illegal() {
    assert_illegal(
        WorkerStatus::Failed.transition_to(WorkerStatus::Failed, "w1"),
        "Failed",
        "Failed",
    );
}

// =========================================================================
// Sequence tests — multi-step transition chains
// =========================================================================

#[test]
fn sequence_run_happy_path() {
    let s = RunStatus::Created;
    let s = s.transition_to(RunStatus::Running, "r1").unwrap();
    assert_eq!(s, RunStatus::Running);
    let s = s.transition_to(RunStatus::Completed, "r1").unwrap();
    assert_eq!(s, RunStatus::Completed);
}

#[test]
fn sequence_run_failure() {
    let s = RunStatus::Created;
    let s = s.transition_to(RunStatus::Running, "r1").unwrap();
    assert_eq!(s, RunStatus::Running);
    let s = s.transition_to(RunStatus::Failed, "r1").unwrap();
    assert_eq!(s, RunStatus::Failed);
}

#[test]
fn sequence_run_blocked_unblock() {
    let s = RunStatus::Created;
    let s = s.transition_to(RunStatus::Running, "r1").unwrap();
    assert_eq!(s, RunStatus::Running);
    let s = s.transition_to(RunStatus::Blocked, "r1").unwrap();
    assert_eq!(s, RunStatus::Blocked);
    let s = s.transition_to(RunStatus::Running, "r1").unwrap();
    assert_eq!(s, RunStatus::Running);
    let s = s.transition_to(RunStatus::Completed, "r1").unwrap();
    assert_eq!(s, RunStatus::Completed);
}

#[test]
fn sequence_attempt_full_dispatch() {
    let s = AttemptStatus::Created;
    let s = s.transition_to(AttemptStatus::Dispatching, "a1").unwrap();
    assert_eq!(s, AttemptStatus::Dispatching);
    let s = s.transition_to(AttemptStatus::Running, "a1").unwrap();
    assert_eq!(s, AttemptStatus::Running);
    let s = s
        .transition_to(AttemptStatus::HandoffReceived, "a1")
        .unwrap();
    assert_eq!(s, AttemptStatus::HandoffReceived);
    let s = s.transition_to(AttemptStatus::OutputBound, "a1").unwrap();
    assert_eq!(s, AttemptStatus::OutputBound);
    let s = s.transition_to(AttemptStatus::Completed, "a1").unwrap();
    assert_eq!(s, AttemptStatus::Completed);
}

#[test]
fn sequence_attempt_failure_during_dispatch() {
    let s = AttemptStatus::Created;
    let s = s.transition_to(AttemptStatus::Dispatching, "a1").unwrap();
    assert_eq!(s, AttemptStatus::Dispatching);
    let s = s.transition_to(AttemptStatus::Running, "a1").unwrap();
    assert_eq!(s, AttemptStatus::Running);
    let s = s.transition_to(AttemptStatus::Failed, "a1").unwrap();
    assert_eq!(s, AttemptStatus::Failed);
}

#[test]
fn sequence_worker_full_lifecycle() {
    let s = WorkerStatus::Pending;
    let s = s.transition_to(WorkerStatus::Dispatched, "w1").unwrap();
    assert_eq!(s, WorkerStatus::Dispatched);
    let s = s.transition_to(WorkerStatus::Running, "w1").unwrap();
    assert_eq!(s, WorkerStatus::Running);
    let s = s.transition_to(WorkerStatus::Completed, "w1").unwrap();
    assert_eq!(s, WorkerStatus::Completed);
}

// =========================================================================
// Coverage summary — counts total transitions tested vs total possible
// =========================================================================

#[test]
fn transition_coverage_summary() {
    // RunStatus: 5 variants, 25 pairs, 6 legal, 19 illegal = 25 tested
    // PhaseStatus: 6 variants, 36 pairs, 7 legal, 29 illegal = 36 tested
    // StepStatus: 5 variants, 25 pairs, 6 legal, 19 illegal = 25 tested
    // AttemptStatus: 7 variants, 49 pairs, 8 legal, 41 illegal = 49 tested
    // WorkerStatus: 5 variants, 25 pairs, 4 legal, 21 illegal = 25 tested

    let run_variants = 5u64;
    let phase_variants = 6u64;
    let step_variants = 5u64;
    let attempt_variants = 7u64;
    let worker_variants = 5u64;

    let run_total = run_variants * run_variants;
    let phase_total = phase_variants * phase_variants;
    let step_total = step_variants * step_variants;
    let attempt_total = attempt_variants * attempt_variants;
    let worker_total = worker_variants * worker_variants;

    let run_tested: u64 = 6 + 19; // legal + illegal
    let phase_tested: u64 = 7 + 29;
    let step_tested: u64 = 6 + 19;
    let attempt_tested: u64 = 8 + 41;
    let worker_tested: u64 = 4 + 21;

    assert_eq!(run_tested, run_total, "RunStatus coverage incomplete");
    assert_eq!(phase_tested, phase_total, "PhaseStatus coverage incomplete");
    assert_eq!(step_tested, step_total, "StepStatus coverage incomplete");
    assert_eq!(
        attempt_tested, attempt_total,
        "AttemptStatus coverage incomplete"
    );
    assert_eq!(
        worker_tested, worker_total,
        "WorkerStatus coverage incomplete"
    );

    let total_possible = run_total + phase_total + step_total + attempt_total + worker_total;
    let total_tested = run_tested + phase_tested + step_tested + attempt_tested + worker_tested;
    let pct = (total_tested as f64 / total_possible as f64) * 100.0;

    eprintln!();
    eprintln!("=== State Machine Transition Coverage ===");
    eprintln!(
        "  RunStatus:     {run_tested:>3}/{run_total:>3} ({:.0}%)",
        (run_tested as f64 / run_total as f64) * 100.0
    );
    eprintln!(
        "  PhaseStatus:   {phase_tested:>3}/{phase_total:>3} ({:.0}%)",
        (phase_tested as f64 / phase_total as f64) * 100.0
    );
    eprintln!(
        "  StepStatus:    {step_tested:>3}/{step_total:>3} ({:.0}%)",
        (step_tested as f64 / step_total as f64) * 100.0
    );
    eprintln!(
        "  AttemptStatus: {attempt_tested:>3}/{attempt_total:>3} ({:.0}%)",
        (attempt_tested as f64 / attempt_total as f64) * 100.0
    );
    eprintln!(
        "  WorkerStatus:  {worker_tested:>3}/{worker_total:>3} ({:.0}%)",
        (worker_tested as f64 / worker_total as f64) * 100.0
    );
    eprintln!("  ─────────────────────────────────────");
    eprintln!("  Total:         {total_tested:>3}/{total_possible:>3} ({pct:.0}%)");
    eprintln!("==========================================");
}
