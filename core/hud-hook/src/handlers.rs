use std::sync::atomic::Ordering;

use capacitor_core::{
    domain::{
        IngestHookEventCommand, IngestShellSignalCommand, MutateDelegationCommand,
        MutateRunCommand, ResolveRoutingCommand, ShellUnregisterCommand,
    },
    runtime::service::RuntimeServiceBootstrap,
};

use crate::{
    hook_types::HookInput,
    serve::{
        adjusted_gc_reference_time, json_content_type, json_error, parse_since_version, read_json,
        respond_json, runtime_poll_timeout, PollWaiterGuard, RuntimeServerState, SHUTDOWN,
    },
};

pub(super) fn handle_health(
    request: tiny_http::Request,
    runtime_service: Option<&RuntimeServiceBootstrap>,
) {
    let resp = if let Some(bootstrap) = runtime_service {
        let authorization = request
            .headers()
            .iter()
            .find(|header| header.field.equiv("Authorization"))
            .map(|header| header.value.as_str());

        if !bootstrap.is_authorized(authorization) {
            json_error(401, "unauthorized")
        } else {
            tiny_http::Response::from_string(
                serde_json::to_string(&bootstrap.health_report())
                    .unwrap_or_else(|_| r#"{"error":"health unavailable"}"#.to_string()),
            )
            .with_status_code(200)
            .with_header(json_content_type())
            .boxed()
        }
    } else {
        tiny_http::Response::from_string(r#"{"status":"ok"}"#)
            .with_status_code(200)
            .with_header(json_content_type())
            .boxed()
    };
    if let Err(e) = request.respond(resp) {
        tracing::debug!("failed to send HTTP response: {e}");
    }
}

pub(super) fn handle_runtime_snapshot(request: tiny_http::Request, state: &RuntimeServerState) {
    let Some(runtime) = state.runtime.as_ref() else {
        if let Err(e) = request.respond(json_error(404, "runtime service not enabled")) {
            tracing::debug!("failed to send HTTP response: {e}");
        }
        return;
    };

    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        if let Err(e) = request.respond(json_error(401, "unauthorized")) {
            tracing::debug!("failed to send HTTP response: {e}");
        }
        return;
    }

    match runtime.app_snapshot() {
        Ok(snapshot) => {
            if let Ok(mut guard) = state.last_snapshot_served_at.lock() {
                *guard = Some(chrono::Utc::now().to_rfc3339());
            } else {
                tracing::warn!("last_snapshot_served_at mutex poisoned — timestamp not updated");
            }
            respond_json(request, 200, &snapshot);
        }
        Err(error) => {
            tracing::warn!(error = %error, "Runtime snapshot request failed");
            if let Err(e) = request.respond(json_error(500, "runtime snapshot failed")) {
                tracing::debug!("failed to send HTTP response: {e}");
            }
        }
    }
}

pub(super) fn handle_runtime_poll_snapshot(
    request: tiny_http::Request,
    state: &RuntimeServerState,
) {
    let Some(runtime) = state.runtime.as_ref() else {
        if let Err(e) = request.respond(json_error(404, "runtime service not enabled")) {
            tracing::debug!("failed to send HTTP response: {e}");
        }
        return;
    };

    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        if let Err(e) = request.respond(json_error(401, "unauthorized")) {
            tracing::debug!("failed to send HTTP response: {e}");
        }
        return;
    }

    let since_version = match parse_since_version(request.url()) {
        Some(since_version) => since_version,
        None => {
            if let Err(e) = request.respond(json_error(
                400,
                "missing or invalid since_version parameter",
            )) {
                tracing::debug!("failed to send HTTP response: {e}");
            }
            return;
        }
    };

    let _waiter_guard = match PollWaiterGuard::try_acquire() {
        Some(guard) => guard,
        None => {
            if let Err(e) = request.respond(json_error(503, "too many concurrent poll requests")) {
                tracing::debug!("failed to send HTTP response: {e}");
            }
            return;
        }
    };

    if SHUTDOWN.load(Ordering::Relaxed) {
        if let Err(e) = request.respond(json_error(503, "shutting down")) {
            tracing::debug!("failed to send HTTP response: {e}");
        }
        return;
    }

    let version_change = runtime.wait_for_version_change(since_version, runtime_poll_timeout());

    if SHUTDOWN.load(Ordering::Relaxed) {
        if let Err(e) = request.respond(json_error(503, "shutting down")) {
            tracing::debug!("failed to send HTTP response: {e}");
        }
        return;
    }

    match version_change {
        Some(_) => match runtime.app_snapshot() {
            Ok(snapshot) => match serde_json::to_value(&snapshot) {
                Ok(mut value) => {
                    if let Some(object) = value.as_object_mut() {
                        object.insert("changed".to_string(), serde_json::Value::Bool(true));
                    }
                    if let Ok(mut guard) = state.last_snapshot_served_at.lock() {
                        *guard = Some(chrono::Utc::now().to_rfc3339());
                    } else {
                        tracing::warn!(
                            "last_snapshot_served_at mutex poisoned — timestamp not updated"
                        );
                    }
                    respond_json(request, 200, &value);
                }
                Err(_) => {
                    if let Err(e) = request.respond(json_error(500, "serialization failed")) {
                        tracing::debug!("failed to send HTTP response: {e}");
                    }
                }
            },
            Err(error) => {
                tracing::warn!(error = %error, "Long-poll snapshot request failed");
                if let Err(e) = request.respond(json_error(500, "runtime snapshot failed")) {
                    tracing::debug!("failed to send HTTP response: {e}");
                }
            }
        },
        None => respond_json(
            request,
            200,
            &serde_json::json!({
                "changed": false,
                "snapshot_version": runtime.snapshot_version(),
            }),
        ),
    }
}

pub(super) fn handle_runtime_ingest_hook_event(
    mut request: tiny_http::Request,
    state: &RuntimeServerState,
) {
    let Some(runtime) = state.runtime.as_ref() else {
        if let Err(e) = request.respond(json_error(404, "runtime service not enabled")) {
            tracing::debug!("failed to send HTTP response: {e}");
        }
        return;
    };

    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        if let Err(e) = request.respond(json_error(401, "unauthorized")) {
            tracing::debug!("failed to send HTTP response: {e}");
        }
        return;
    }

    let command = match read_json::<IngestHookEventCommand>(&mut request) {
        Ok(command) => command,
        Err(response) => {
            if let Err(e) = request.respond(response) {
                tracing::debug!("failed to send HTTP response: {e}");
            }
            return;
        }
    };

    let gc_reference_time = adjusted_gc_reference_time(&state.sleep_tracker);
    match runtime.ingest_hook_event_with_gc_reference_time(command, gc_reference_time) {
        Ok(outcome) => {
            if let Ok(mut guard) = state.last_hook_event_at.lock() {
                *guard = Some(chrono::Utc::now().to_rfc3339());
            } else {
                tracing::warn!("last_hook_event_at mutex poisoned — timestamp not updated");
            }
            respond_json(request, 200, &outcome);
        }
        Err(error) => {
            tracing::warn!(error = %error, "Runtime hook ingest request failed");
            if let Err(e) = request.respond(json_error(500, "runtime hook ingest failed")) {
                tracing::debug!("failed to send HTTP response: {e}");
            }
        }
    }
}

pub(super) fn handle_runtime_power_sleep(request: tiny_http::Request, state: &RuntimeServerState) {
    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        if let Err(e) = request.respond(json_error(401, "unauthorized")) {
            tracing::debug!("failed to send HTTP response: {e}");
        }
        return;
    }

    let generation = match state.sleep_tracker.lock() {
        Ok(mut sleep_tracker) => {
            sleep_tracker.report_sleep();
            sleep_tracker.generation()
        }
        Err(_) => {
            if let Err(e) = request.respond(json_error(500, "sleep tracker unavailable")) {
                tracing::debug!("failed to send HTTP response: {e}");
            }
            return;
        }
    };

    respond_json(
        request,
        200,
        &serde_json::json!({ "ok": true, "generation": generation }),
    );
}

pub(super) fn handle_runtime_power_wake(request: tiny_http::Request, state: &RuntimeServerState) {
    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        if let Err(e) = request.respond(json_error(401, "unauthorized")) {
            tracing::debug!("failed to send HTTP response: {e}");
        }
        return;
    }

    let generation = match state.sleep_tracker.lock() {
        Ok(mut sleep_tracker) => {
            sleep_tracker.report_wake();
            sleep_tracker.generation()
        }
        Err(_) => {
            if let Err(e) = request.respond(json_error(500, "sleep tracker unavailable")) {
                tracing::debug!("failed to send HTTP response: {e}");
            }
            return;
        }
    };

    respond_json(
        request,
        200,
        &serde_json::json!({ "ok": true, "generation": generation }),
    );
}

pub(super) fn handle_runtime_resolve_routing(
    mut request: tiny_http::Request,
    state: &RuntimeServerState,
) {
    let Some(runtime) = state.runtime.as_ref() else {
        if let Err(e) = request.respond(json_error(404, "runtime service not enabled")) {
            tracing::debug!("failed to send HTTP response: {e}");
        }
        return;
    };

    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        if let Err(e) = request.respond(json_error(401, "unauthorized")) {
            tracing::debug!("failed to send HTTP response: {e}");
        }
        return;
    }

    let command = match read_json::<ResolveRoutingCommand>(&mut request) {
        Ok(command) => command,
        Err(response) => {
            if let Err(e) = request.respond(response) {
                tracing::debug!("failed to send HTTP response: {e}");
            }
            return;
        }
    };

    match runtime.resolve_routing(command) {
        Ok(route) => respond_json(request, 200, &route),
        Err(error) => {
            tracing::warn!(error = %error, "Runtime route resolve request failed");
            if let Err(e) = request.respond(json_error(500, "runtime route resolve failed")) {
                tracing::debug!("failed to send HTTP response: {e}");
            }
        }
    }
}

pub(super) fn handle_runtime_ingest_shell_signal(
    mut request: tiny_http::Request,
    state: &RuntimeServerState,
) {
    let Some(runtime) = state.runtime.as_ref() else {
        if let Err(e) = request.respond(json_error(404, "runtime service not enabled")) {
            tracing::debug!("failed to send HTTP response: {e}");
        }
        return;
    };

    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        if let Err(e) = request.respond(json_error(401, "unauthorized")) {
            tracing::debug!("failed to send HTTP response: {e}");
        }
        return;
    }

    let command = match read_json::<IngestShellSignalCommand>(&mut request) {
        Ok(command) => command,
        Err(response) => {
            if let Err(e) = request.respond(response) {
                tracing::debug!("failed to send HTTP response: {e}");
            }
            return;
        }
    };

    match runtime.ingest_shell_signal(command) {
        Ok(outcome) => {
            if let Ok(mut guard) = state.last_shell_signal_at.lock() {
                *guard = Some(chrono::Utc::now().to_rfc3339());
            } else {
                tracing::warn!("last_shell_signal_at mutex poisoned — timestamp not updated");
            }
            respond_json(request, 200, &outcome);
        }
        Err(error) => {
            tracing::warn!(error = %error, "Runtime shell ingest request failed");
            if let Err(e) = request.respond(json_error(500, "runtime shell ingest failed")) {
                tracing::debug!("failed to send HTTP response: {e}");
            }
        }
    }
}

pub(super) fn handle_runtime_shell_unregister(
    mut request: tiny_http::Request,
    state: &RuntimeServerState,
) {
    let Some(runtime) = state.runtime.as_ref() else {
        if let Err(e) = request.respond(json_error(404, "runtime service not enabled")) {
            tracing::debug!("failed to send HTTP response: {e}");
        }
        return;
    };

    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        if let Err(e) = request.respond(json_error(401, "unauthorized")) {
            tracing::debug!("failed to send HTTP response: {e}");
        }
        return;
    }

    let command = match read_json::<ShellUnregisterCommand>(&mut request) {
        Ok(command) => command,
        Err(response) => {
            if let Err(e) = request.respond(response) {
                tracing::debug!("failed to send HTTP response: {e}");
            }
            return;
        }
    };

    match runtime.unregister_shell(command) {
        Ok(outcome) => respond_json(request, 200, &outcome),
        Err(error) => {
            tracing::warn!(error = %error, "Runtime shell unregister request failed");
            if let Err(e) = request.respond(json_error(500, "runtime shell unregister failed")) {
                tracing::debug!("failed to send HTTP response: {e}");
            }
        }
    }
}

pub(super) fn handle_runtime_diagnostics(request: tiny_http::Request, state: &RuntimeServerState) {
    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        if let Err(e) = request.respond(json_error(401, "unauthorized")) {
            tracing::debug!("failed to send HTTP response: {e}");
        }
        return;
    }

    let uptime_seconds = state.started_at.elapsed().as_secs();
    let gc_cycle_count = state
        .gc_cycle_count
        .load(std::sync::atomic::Ordering::Relaxed);
    let gc_last_changed = state
        .gc_last_changed
        .load(std::sync::atomic::Ordering::Relaxed);

    let last_snapshot_served_at = match state.last_snapshot_served_at.lock() {
        Ok(guard) => guard.clone(),
        Err(_) => {
            tracing::warn!("last_snapshot_served_at mutex poisoned — reporting None");
            None
        }
    };
    let last_hook_event_at = match state.last_hook_event_at.lock() {
        Ok(guard) => guard.clone(),
        Err(_) => {
            tracing::warn!("last_hook_event_at mutex poisoned — reporting None");
            None
        }
    };
    let last_shell_signal_at = match state.last_shell_signal_at.lock() {
        Ok(guard) => guard.clone(),
        Err(_) => {
            tracing::warn!("last_shell_signal_at mutex poisoned — reporting None");
            None
        }
    };

    let payload = serde_json::json!({
        "uptime_seconds": uptime_seconds,
        "gc_cycle_count": gc_cycle_count,
        "gc_last_changed": gc_last_changed,
        "last_snapshot_served_at": last_snapshot_served_at,
        "last_hook_event_at": last_hook_event_at,
        "last_shell_signal_at": last_shell_signal_at,
    });

    respond_json(request, 200, &payload);
}

pub(super) fn handle_runtime_mutate_delegation(
    mut request: tiny_http::Request,
    state: &RuntimeServerState,
) {
    let Some(runtime) = state.runtime.as_ref() else {
        if let Err(e) = request.respond(json_error(404, "runtime service not enabled")) {
            tracing::debug!("failed to send HTTP response: {e}");
        }
        return;
    };

    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        if let Err(e) = request.respond(json_error(401, "unauthorized")) {
            tracing::debug!("failed to send HTTP response: {e}");
        }
        return;
    }

    let command = match read_json::<MutateDelegationCommand>(&mut request) {
        Ok(command) => command,
        Err(response) => {
            if let Err(e) = request.respond(response) {
                tracing::debug!("failed to send HTTP response: {e}");
            }
            return;
        }
    };

    match runtime.mutate_delegation(command) {
        Ok(outcome) => respond_json(request, 200, &outcome),
        Err(error) => {
            tracing::warn!(error = %error, "Runtime delegation mutation request failed");
            if let Err(e) = request.respond(json_error(500, "runtime delegation mutation failed")) {
                tracing::debug!("failed to send HTTP response: {e}");
            }
        }
    }
}

pub(super) fn handle_runtime_mutate_run(
    mut request: tiny_http::Request,
    state: &RuntimeServerState,
) {
    let Some(runtime) = state.runtime.as_ref() else {
        if let Err(e) = request.respond(json_error(404, "runtime service not enabled")) {
            tracing::debug!("failed to send HTTP response: {e}");
        }
        return;
    };

    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        if let Err(e) = request.respond(json_error(401, "unauthorized")) {
            tracing::debug!("failed to send HTTP response: {e}");
        }
        return;
    }

    let command = match read_json::<MutateRunCommand>(&mut request) {
        Ok(command) => command,
        Err(response) => {
            if let Err(e) = request.respond(response) {
                tracing::debug!("failed to send HTTP response: {e}");
            }
            return;
        }
    };

    let command_clone = command.clone();
    match runtime.mutate_run(command) {
        Ok(outcome) => {
            crate::checkpoint_bridge_relay::relay_decision(
                &state.home_dir,
                &command_clone,
                &outcome,
            );
            respond_json(request, 200, &outcome);
        }
        Err(error) => {
            tracing::warn!(error = %error, "Runtime run mutation request failed");
            if let Err(e) = request.respond(json_error(500, "runtime run mutation failed")) {
                tracing::debug!("failed to send HTTP response: {e}");
            }
        }
    }
}

pub(super) fn handle_hook(mut request: tiny_http::Request, state: &RuntimeServerState) {
    // Require auth when bootstrap is configured (runtime service mode).
    // Legacy mode (no bootstrap) allows unauthenticated access.
    // NOTE: This intentionally diverges from authorize_runtime_request() which
    // rejects when bootstrap is None. /hook must remain open in legacy mode
    // because Claude CLI hooks fire before the runtime service is available.
    if let Some(bootstrap) = state.bootstrap.as_ref() {
        let authorization = request
            .headers()
            .iter()
            .find(|header| header.field.equiv("Authorization"))
            .map(|header| header.value.as_str());
        if !bootstrap.is_authorized(authorization) {
            if let Err(e) = request.respond(json_error(401, "unauthorized")) {
                tracing::debug!("failed to send HTTP response: {e}");
            }
            return;
        }
    }

    let hook_input: HookInput = match read_json::<HookInput>(&mut request) {
        Ok(input) => input,
        Err(response) => {
            if let Err(e) = request.respond(response) {
                tracing::debug!("failed to send HTTP response: {e}");
            }
            return;
        }
    };

    match crate::handle::handle_hook_input(hook_input) {
        Ok(()) => {
            respond_json(request, 200, &serde_json::json!({ "status": "ok" }));
        }
        Err(error) => {
            tracing::warn!(error = %error, "Hook processing failed");
            if let Err(e) = request.respond(json_error(500, "hook processing failed")) {
                tracing::debug!("failed to send HTTP response: {e}");
            }
        }
    }
}

pub(super) fn respond_not_found(request: tiny_http::Request) {
    if let Err(e) = request.respond(json_error(404, "not found")) {
        tracing::debug!("failed to send HTTP response: {e}");
    }
}

fn authorize_runtime_request(
    request: &tiny_http::Request,
    runtime_service: Option<&RuntimeServiceBootstrap>,
) -> bool {
    let Some(bootstrap) = runtime_service else {
        return false;
    };

    let authorization = request
        .headers()
        .iter()
        .find(|header| header.field.equiv("Authorization"))
        .map(|header| header.value.as_str());

    bootstrap.is_authorized(authorization)
}
