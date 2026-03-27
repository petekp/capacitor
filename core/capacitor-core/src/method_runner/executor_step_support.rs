/// Evaluate whether the completion policy is satisfied given worker results.
fn evaluate_completion_policy(
    policy: CompletionPolicy,
    results: &[(String, bool)],
    workers: &[crate::method_runner::definition::NormalizedWorkerSpec],
) -> bool {
    match policy {
        CompletionPolicy::AllComplete => {
            // All workers must have succeeded
            results.iter().all(|(_, ok)| *ok)
        }
        CompletionPolicy::FirstClean => {
            // First worker in definition order that succeeded is enough.
            // We check workers in definition order, not results order.
            for worker_spec in workers {
                if let Some((_, ok)) = results.iter().find(|(id, _)| *id == worker_spec.id) {
                    if *ok {
                        return true;
                    }
                }
            }
            false
        }
    }
}

/// Bind outputs for a successful attempt. Emits OutputBound events.
#[allow(clippy::too_many_arguments)]
fn bind_attempt_outputs(
    _paths: &MethodRunPaths,
    events_path: &Path,
    run_id: &str,
    current_seq: &mut u64,
    phase_id: &str,
    step: &NormalizedStep,
    attempt: u32,
    workers: &[crate::method_runner::definition::NormalizedWorkerSpec],
) -> Result<(), RunError> {
    let attempt_dir = _paths.attempt_dir(phase_id, &step.id, attempt);

    // Determine which worker to bind from based on completion policy
    let binding_worker_id = match step.completion_policy {
        CompletionPolicy::FirstClean => {
            // Use the first worker in definition order (for first-clean,
            // that's the winning worker)
            workers.first().map(|w| w.id.as_str()).unwrap_or("primary")
        }
        CompletionPolicy::AllComplete => {
            // For all_complete with single worker, use "primary"
            // For multi-worker all_complete, outputs come from each worker
            workers.first().map(|w| w.id.as_str()).unwrap_or("primary")
        }
    };

    let mut output_bindings: BTreeMap<String, serde_json::Value> = BTreeMap::new();
    for (output_name, output_def) in &step.outputs {
        let resolved_path = output_def.path.clone();
        output_bindings.insert(
            output_name.clone(),
            serde_json::json!({
                "path": resolved_path,
                "type": output_def.output_type,
                "worker_id": binding_worker_id,
            }),
        );

        // OutputBound event
        let mut env = make_envelope(run_id, MethodEventKind::OutputBound);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
        env.worker_id = Some(binding_worker_id.to_string());
        env.payload = serde_json::json!({
            "name": output_name,
            "path": resolved_path,
            "type": output_def.output_type,
        });
        append_event(events_path, &mut env, current_seq)?;
    }

    let bindings_json = serde_json::json!({ "outputs": output_bindings });
    let json = serde_json::to_string_pretty(&bindings_json).map_err(std::io::Error::other)?;
    std::fs::write(attempt_dir.join("output-bindings.json"), json)?;

    Ok(())
}

/// Write input-bindings.json to an attempt directory.
fn write_input_bindings(attempt_dir: &Path, inputs: &[String]) -> Result<(), std::io::Error> {
    let inputs_map: BTreeMap<String, String> = inputs
        .iter()
        .map(|input| (input.clone(), input.clone()))
        .collect();
    let bindings = serde_json::json!({ "inputs": inputs_map });
    let json = serde_json::to_string_pretty(&bindings).map_err(std::io::Error::other)?;
    std::fs::write(attempt_dir.join("input-bindings.json"), json)
}

/// Write attempt.json with status and timestamps.
fn write_attempt_json(
    attempt_dir: &Path,
    phase_id: &str,
    step_id: &str,
    attempt: u32,
    status: &str,
) -> Result<(), std::io::Error> {
    let attempt_json = serde_json::json!({
        "phase_id": phase_id,
        "step_id": step_id,
        "attempt": attempt,
        "status": status,
        "started_at": chrono::Utc::now().to_rfc3339(),
        "completed_at": chrono::Utc::now().to_rfc3339(),
    });
    let json = serde_json::to_string_pretty(&attempt_json).map_err(std::io::Error::other)?;
    std::fs::write(attempt_dir.join("attempt.json"), json)
}

/// Resolve input references from current state.
fn resolve_step_inputs(
    events_path: &Path,
    inputs: &[String],
) -> Result<BTreeMap<String, String>, RunError> {
    let current_events = crate::method_runner::events::recover_events(events_path)?;
    let current_state = project(&current_events)?;
    let mut resolved = BTreeMap::new();
    for input_ref in inputs {
        let segments: Vec<&str> = input_ref.split('.').collect();
        if segments.len() >= 3 {
            let ref_phase = segments[0];
            let ref_step = segments[1];
            let ref_output = segments.last().unwrap();
            if let Some(phase_state) = current_state.phases.get(ref_phase) {
                if let Some(step_state) = phase_state.steps.get(ref_step) {
                    if let Some(output_path) = step_state.outputs.get(*ref_output) {
                        resolved.insert(input_ref.clone(), output_path.clone());
                    }
                }
            }
        }
        if !resolved.contains_key(input_ref) {
            resolved.insert(input_ref.clone(), format!("(unresolved: {})", input_ref));
        }
    }
    Ok(resolved)
}

/// Write synthesis output artifacts to the attempt directory.
fn write_synthesis_output_artifacts(
    attempt_dir: &Path,
    step: &NormalizedStep,
    resolved_inputs: &BTreeMap<String, String>,
) -> Result<(), RunError> {
    for output_def in step.outputs.values() {
        let output_path = attempt_dir.join(&output_def.path);
        if let Some(parent) = output_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let instructions = match &step.config {
            StepActionConfig::Synthesis { instructions, .. } => instructions.clone(),
            _ => String::new(),
        };
        let mut content = format!("# Synthesized\n\nInstructions: {}\n", instructions);
        if !resolved_inputs.is_empty() {
            content.push_str("\n## Consumed Inputs\n\n");
            for (input_name, input_path) in resolved_inputs {
                content.push_str(&format!("- {}: {}\n", input_name, input_path));
            }
        }
        content.push('\n');
        std::fs::write(&output_path, content)?;
    }
    Ok(())
}

/// Shared setup: emit StepStarted, create attempt dir, write input-bindings, emit AttemptStarted.
/// Returns the attempt directory path and the attempt start instant.
fn emit_step_and_attempt_start(
    paths: &MethodRunPaths,
    events_path: &Path,
    run_id: &str,
    current_seq: &mut u64,
    phase_id: &str,
    step: &NormalizedStep,
    attempt: u32,
) -> Result<(std::path::PathBuf, std::time::Instant), RunError> {
    // StepStarted
    {
        let mut env = make_envelope(run_id, MethodEventKind::StepStarted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        append_event(events_path, &mut env, current_seq)?;
    }
    let attempt_dir = paths.attempt_dir(phase_id, &step.id, attempt);
    std::fs::create_dir_all(&attempt_dir)?;
    write_input_bindings(&attempt_dir, &step.inputs)?;
    let attempt_start = std::time::Instant::now();
    // AttemptStarted
    {
        let mut env = make_envelope(run_id, MethodEventKind::AttemptStarted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
        append_event(events_path, &mut env, current_seq)?;
    }
    Ok((attempt_dir, attempt_start))
}

/// Shared tail: emit OutputBound events, write output-bindings.json, write attempt.json,
/// emit AttemptCompleted and StepCompleted.
#[allow(clippy::too_many_arguments)]
fn emit_output_bindings_and_complete(
    attempt_dir: &Path,
    events_path: &Path,
    run_id: &str,
    current_seq: &mut u64,
    phase_id: &str,
    step: &NormalizedStep,
    attempt: u32,
    attempt_start: std::time::Instant,
    action_label: &str,
) -> Result<(), RunError> {
    // Write output-bindings.json and emit OutputBound events
    {
        let mut output_bindings: BTreeMap<String, serde_json::Value> = BTreeMap::new();
        for (output_name, output_def) in &step.outputs {
            let resolved_path = output_def.path.clone();
            output_bindings.insert(
                output_name.clone(),
                serde_json::json!({
                    "path": resolved_path,
                    "type": output_def.output_type,
                }),
            );
            let mut env = make_envelope(run_id, MethodEventKind::OutputBound);
            env.phase_id = Some(phase_id.to_string());
            env.step_id = Some(step.id.clone());
            env.attempt = Some(attempt);
            env.payload = serde_json::json!({
                "name": output_name,
                "path": resolved_path,
                "type": output_def.output_type,
            });
            append_event(events_path, &mut env, current_seq)?;
        }
        let bindings_json = serde_json::json!({ "outputs": output_bindings });
        let json = serde_json::to_string_pretty(&bindings_json).map_err(std::io::Error::other)?;
        std::fs::write(attempt_dir.join("output-bindings.json"), json)?;
    }
    // Write attempt.json
    {
        let attempt_json = serde_json::json!({
            "phase_id": phase_id,
            "step_id": step.id,
            "attempt": attempt,
            "status": "completed",
            "action": action_label,
            "started_at": chrono::Utc::now().to_rfc3339(),
            "completed_at": chrono::Utc::now().to_rfc3339(),
        });
        let json = serde_json::to_string_pretty(&attempt_json).map_err(std::io::Error::other)?;
        std::fs::write(attempt_dir.join("attempt.json"), json)?;
    }
    // AttemptCompleted with timing
    {
        let elapsed_ms = attempt_start.elapsed().as_millis() as u64;
        let mut env = make_envelope(run_id, MethodEventKind::AttemptCompleted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        env.attempt = Some(attempt);
        env.payload = serde_json::json!({ "elapsed_ms": elapsed_ms });
        append_event(events_path, &mut env, current_seq)?;
    }
    // StepCompleted
    {
        let mut env = make_envelope(run_id, MethodEventKind::StepCompleted);
        env.phase_id = Some(phase_id.to_string());
        env.step_id = Some(step.id.clone());
        append_event(events_path, &mut env, current_seq)?;
    }
    Ok(())
}
