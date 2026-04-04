use std::sync::atomic::Ordering;

use capacitor_core::{
    domain::{
        IngestHookEventCommand, IngestShellSignalCommand, MutateDelegationCommand,
        MutateRunCommand, ResolveRoutingCommand,
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
    let _ = request.respond(resp);
}

pub(super) fn handle_runtime_snapshot(request: tiny_http::Request, state: &RuntimeServerState) {
    let Some(runtime) = state.runtime.as_ref() else {
        let _ = request.respond(json_error(404, "runtime service not enabled"));
        return;
    };

    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        let _ = request.respond(json_error(401, "unauthorized"));
        return;
    }

    match runtime.app_snapshot() {
        Ok(snapshot) => respond_json(request, 200, &snapshot),
        Err(error) => {
            tracing::warn!(error = %error, "Runtime snapshot request failed");
            let _ = request.respond(json_error(500, "runtime snapshot failed"));
        }
    }
}

pub(super) fn handle_runtime_poll_snapshot(
    request: tiny_http::Request,
    state: &RuntimeServerState,
) {
    let Some(runtime) = state.runtime.as_ref() else {
        let _ = request.respond(json_error(404, "runtime service not enabled"));
        return;
    };

    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        let _ = request.respond(json_error(401, "unauthorized"));
        return;
    }

    let since_version = match parse_since_version(request.url()) {
        Some(since_version) => since_version,
        None => {
            let _ = request.respond(json_error(
                400,
                "missing or invalid since_version parameter",
            ));
            return;
        }
    };

    let _waiter_guard = match PollWaiterGuard::try_acquire() {
        Some(guard) => guard,
        None => {
            let _ = request.respond(json_error(503, "too many concurrent poll requests"));
            return;
        }
    };

    if SHUTDOWN.load(Ordering::Relaxed) {
        let _ = request.respond(json_error(503, "shutting down"));
        return;
    }

    let version_change = runtime.wait_for_version_change(since_version, runtime_poll_timeout());

    if SHUTDOWN.load(Ordering::Relaxed) {
        let _ = request.respond(json_error(503, "shutting down"));
        return;
    }

    match version_change {
        Some(_) => match runtime.app_snapshot() {
            Ok(snapshot) => match serde_json::to_value(&snapshot) {
                Ok(mut value) => {
                    if let Some(object) = value.as_object_mut() {
                        object.insert("changed".to_string(), serde_json::Value::Bool(true));
                    }
                    respond_json(request, 200, &value);
                }
                Err(_) => {
                    let _ = request.respond(json_error(500, "serialization failed"));
                }
            },
            Err(error) => {
                tracing::warn!(error = %error, "Long-poll snapshot request failed");
                let _ = request.respond(json_error(500, "runtime snapshot failed"));
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
        let _ = request.respond(json_error(404, "runtime service not enabled"));
        return;
    };

    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        let _ = request.respond(json_error(401, "unauthorized"));
        return;
    }

    let command = match read_json::<IngestHookEventCommand>(&mut request) {
        Ok(command) => command,
        Err(response) => {
            let _ = request.respond(response);
            return;
        }
    };

    let gc_reference_time = adjusted_gc_reference_time(&state.sleep_tracker);
    match runtime.ingest_hook_event_with_gc_reference_time(command, gc_reference_time) {
        Ok(outcome) => respond_json(request, 200, &outcome),
        Err(error) => {
            tracing::warn!(error = %error, "Runtime hook ingest request failed");
            let _ = request.respond(json_error(500, "runtime hook ingest failed"));
        }
    }
}

pub(super) fn handle_runtime_power_sleep(request: tiny_http::Request, state: &RuntimeServerState) {
    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        let _ = request.respond(json_error(401, "unauthorized"));
        return;
    }

    let generation = match state.sleep_tracker.lock() {
        Ok(mut sleep_tracker) => {
            sleep_tracker.report_sleep();
            sleep_tracker.generation()
        }
        Err(_) => {
            let _ = request.respond(json_error(500, "sleep tracker unavailable"));
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
        let _ = request.respond(json_error(401, "unauthorized"));
        return;
    }

    let generation = match state.sleep_tracker.lock() {
        Ok(mut sleep_tracker) => {
            sleep_tracker.report_wake();
            sleep_tracker.generation()
        }
        Err(_) => {
            let _ = request.respond(json_error(500, "sleep tracker unavailable"));
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
        let _ = request.respond(json_error(404, "runtime service not enabled"));
        return;
    };

    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        let _ = request.respond(json_error(401, "unauthorized"));
        return;
    }

    let command = match read_json::<ResolveRoutingCommand>(&mut request) {
        Ok(command) => command,
        Err(response) => {
            let _ = request.respond(response);
            return;
        }
    };

    match runtime.resolve_routing(command) {
        Ok(route) => respond_json(request, 200, &route),
        Err(error) => {
            tracing::warn!(error = %error, "Runtime route resolve request failed");
            let _ = request.respond(json_error(500, "runtime route resolve failed"));
        }
    }
}

pub(super) fn handle_runtime_ingest_shell_signal(
    mut request: tiny_http::Request,
    state: &RuntimeServerState,
) {
    let Some(runtime) = state.runtime.as_ref() else {
        let _ = request.respond(json_error(404, "runtime service not enabled"));
        return;
    };

    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        let _ = request.respond(json_error(401, "unauthorized"));
        return;
    }

    let command = match read_json::<IngestShellSignalCommand>(&mut request) {
        Ok(command) => command,
        Err(response) => {
            let _ = request.respond(response);
            return;
        }
    };

    match runtime.ingest_shell_signal(command) {
        Ok(outcome) => respond_json(request, 200, &outcome),
        Err(error) => {
            tracing::warn!(error = %error, "Runtime shell ingest request failed");
            let _ = request.respond(json_error(500, "runtime shell ingest failed"));
        }
    }
}

pub(super) fn handle_runtime_mutate_delegation(
    mut request: tiny_http::Request,
    state: &RuntimeServerState,
) {
    let Some(runtime) = state.runtime.as_ref() else {
        let _ = request.respond(json_error(404, "runtime service not enabled"));
        return;
    };

    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        let _ = request.respond(json_error(401, "unauthorized"));
        return;
    }

    let command = match read_json::<MutateDelegationCommand>(&mut request) {
        Ok(command) => command,
        Err(response) => {
            let _ = request.respond(response);
            return;
        }
    };

    match runtime.mutate_delegation(command) {
        Ok(outcome) => respond_json(request, 200, &outcome),
        Err(error) => {
            tracing::warn!(error = %error, "Runtime delegation mutation request failed");
            let _ = request.respond(json_error(500, "runtime delegation mutation failed"));
        }
    }
}

pub(super) fn handle_runtime_mutate_run(
    mut request: tiny_http::Request,
    state: &RuntimeServerState,
) {
    let Some(runtime) = state.runtime.as_ref() else {
        let _ = request.respond(json_error(404, "runtime service not enabled"));
        return;
    };

    if !authorize_runtime_request(&request, state.bootstrap.as_ref()) {
        let _ = request.respond(json_error(401, "unauthorized"));
        return;
    }

    let command = match read_json::<MutateRunCommand>(&mut request) {
        Ok(command) => command,
        Err(response) => {
            let _ = request.respond(response);
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
            let _ = request.respond(json_error(500, "runtime run mutation failed"));
        }
    }
}

pub(super) fn handle_hook(mut request: tiny_http::Request) {
    let hook_input: HookInput = match read_json::<HookInput>(&mut request) {
        Ok(input) => input,
        Err(response) => {
            let _ = request.respond(response);
            return;
        }
    };

    match crate::handle::handle_hook_input(hook_input) {
        Ok(()) => {
            respond_json(request, 200, &serde_json::json!({ "status": "ok" }));
        }
        Err(error) => {
            tracing::warn!(error = %error, "Hook processing failed");
            let _ = request.respond(json_error(500, "hook processing failed"));
        }
    }
}

pub(super) fn respond_not_found(request: tiny_http::Request) {
    let _ = request.respond(json_error(404, "not found"));
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
