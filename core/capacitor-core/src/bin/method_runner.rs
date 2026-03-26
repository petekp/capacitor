use std::env;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use capacitor_core::method_runner::adapter_config::AdapterConfig;
use capacitor_core::method_runner::adapters::{
    FakeInteractiveIO, FakePromptBuilder, FakeWorkerDispatcher, FileInteractiveIO,
};
use capacitor_core::method_runner::checkpoint_bridge::BridgeInteractiveIO;
use capacitor_core::method_runner::definition::DefinitionSource;
use capacitor_core::method_runner::executor::{execute_normalize, execute_run_with_reporter};
use capacitor_core::method_runner::prompt_builder_adapter::ShellPromptBuilder;
use capacitor_core::method_runner::resume::resume_run_with_reporter;
use capacitor_core::method_runner::run_status_reporter::{
    NoopRunStatusReporter, RunStatusReporter, RuntimeRunStatusReporter,
};
use capacitor_core::method_runner::worker_dispatch_adapter::CodexWorkerDispatcher;
use capacitor_core::runtime_service::{RuntimeServiceEndpoint, RUNTIME_SERVICE_DEFAULT_PORT};

#[derive(Debug, Clone, PartialEq, Eq)]
struct BridgeOptions {
    run_id: String,
    project_path: PathBuf,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CommandKind {
    Normalize,
    Run,
    Resume,
}

impl CommandKind {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "normalize" => Some(Self::Normalize),
            "run" => Some(Self::Run),
            "resume" => Some(Self::Resume),
            _ => None,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Normalize => "normalize",
            Self::Run => "run",
            Self::Resume => "resume",
        }
    }
}

#[derive(Debug, Default)]
enum InteractiveMode {
    #[default]
    AutoApprove,
    AutoReject,
    ResponseDir(PathBuf),
}

#[derive(Debug, Default)]
struct ParsedOptions {
    definition: Option<PathBuf>,
    method_id: Option<String>,
    root: Option<PathBuf>,
    real_adapters: bool,
    interactive_mode: InteractiveMode,
    bridge_run_id: Option<String>,
    bridge_project_path: Option<PathBuf>,
    timeout_secs: Option<u64>,
}

/// Embedded YAML definitions for built-in methods.
fn builtin_method_yaml(method_id: &str) -> Option<&'static str> {
    match method_id {
        "execution_only" => Some(include_str!(
            "../../../../methods/builtins/execution_only.yaml"
        )),
        "shape_and_execute" => Some(include_str!(
            "../../../../methods/builtins/shape_and_execute.yaml"
        )),
        "deep_debug" => Some(include_str!("../../../../methods/builtins/deep_debug.yaml")),
        "greenfield_build" => Some(include_str!(
            "../../../../methods/builtins/greenfield_build.yaml"
        )),
        _ => None,
    }
}

/// Write embedded YAML to a temp file in the execution root and return the path.
fn materialize_builtin_method(method_id: &str, root: &Path) -> Result<PathBuf, String> {
    let yaml = builtin_method_yaml(method_id)
        .ok_or_else(|| format!("unknown built-in method: {method_id}"))?;
    let method_dir = root.join(".method");
    std::fs::create_dir_all(&method_dir)
        .map_err(|e| format!("failed to create .method dir: {e}"))?;
    let path = method_dir.join("builtin-definition.yaml");
    std::fs::write(&path, yaml).map_err(|e| format!("failed to write definition: {e}"))?;
    Ok(path)
}

#[derive(Debug)]
struct Command {
    kind: CommandKind,
    definition: Option<PathBuf>,
    root: PathBuf,
    real_adapters: bool,
    interactive_mode: InteractiveMode,
    bridge: Option<BridgeOptions>,
    timeout_secs: Option<u64>,
}

fn resolve_worker_cwd(
    root: &Path,
    bridge: Option<&BridgeOptions>,
    current_dir: Option<PathBuf>,
) -> PathBuf {
    bridge
        .map(|options| options.project_path.clone())
        .or(current_dir)
        .unwrap_or_else(|| root.to_path_buf())
}

fn main() -> ExitCode {
    match parse_cli(env::args_os()) {
        Ok(command) => match command.kind {
            CommandKind::Normalize => {
                let source = DefinitionSource {
                    definition_path: command.definition.expect("--definition required"),
                    execution_root: command.root,
                };
                match execute_normalize(&source) {
                    Ok(()) => {
                        println!("normalize complete: {}", source.execution_root.display());
                        ExitCode::SUCCESS
                    }
                    Err(e) => {
                        eprintln!("error: {e}");
                        ExitCode::FAILURE
                    }
                }
            }
            CommandKind::Run => {
                let source = DefinitionSource {
                    definition_path: command.definition.expect("--definition required"),
                    execution_root: command.root.clone(),
                };
                let interactive_io =
                    match make_interactive_io(&command.interactive_mode, command.bridge.as_ref()) {
                        Ok(interactive_io) => interactive_io,
                        Err(error) => {
                            eprintln!("error: {error}");
                            return ExitCode::FAILURE;
                        }
                    };
                let reporter = match make_run_status_reporter(command.bridge.as_ref()) {
                    Ok(reporter) => reporter,
                    Err(error) => {
                        eprintln!("error: {error}");
                        return ExitCode::FAILURE;
                    }
                };
                let worker_cwd = resolve_worker_cwd(
                    &command.root,
                    command.bridge.as_ref(),
                    env::current_dir().ok(),
                );

                let timeout = Duration::from_secs(command.timeout_secs.unwrap_or(900));

                if command.real_adapters {
                    let script = match find_compose_script() {
                        Ok(p) => p,
                        Err(e) => {
                            eprintln!("error: {e}");
                            return ExitCode::FAILURE;
                        }
                    };
                    let codex = match find_codex_binary() {
                        Ok(p) => p,
                        Err(e) => {
                            eprintln!("error: {e}");
                            return ExitCode::FAILURE;
                        }
                    };
                    let config = match AdapterConfig::new(
                        script,
                        codex,
                        worker_cwd,
                        timeout,
                        Duration::from_secs(5),
                    ) {
                        Ok(c) => c,
                        Err(e) => {
                            eprintln!("adapter config error: {e}");
                            return ExitCode::FAILURE;
                        }
                    };
                    let prompt_builder = ShellPromptBuilder::new(config.clone());
                    let dispatcher = CodexWorkerDispatcher::with_reporter(config, reporter.clone());
                    match execute_run_with_reporter(
                        &source,
                        &prompt_builder,
                        &dispatcher,
                        interactive_io.as_ref(),
                        reporter.as_ref(),
                    ) {
                        Ok(state) => {
                            println!("run complete: run_id={}", state.run_id);
                            println!("status: {:?}", state.status);
                            println!(
                                "phases: {}",
                                state.phases.keys().cloned().collect::<Vec<_>>().join(", ")
                            );
                            ExitCode::SUCCESS
                        }
                        Err(e) => {
                            eprintln!("error: {e}");
                            ExitCode::FAILURE
                        }
                    }
                } else {
                    let prompt_builder = FakePromptBuilder;
                    let dispatcher = FakeWorkerDispatcher;
                    match execute_run_with_reporter(
                        &source,
                        &prompt_builder,
                        &dispatcher,
                        interactive_io.as_ref(),
                        reporter.as_ref(),
                    ) {
                        Ok(state) => {
                            println!("run complete: run_id={}", state.run_id);
                            println!("status: {:?}", state.status);
                            println!(
                                "phases: {}",
                                state.phases.keys().cloned().collect::<Vec<_>>().join(", ")
                            );
                            ExitCode::SUCCESS
                        }
                        Err(e) => {
                            eprintln!("error: {e}");
                            ExitCode::FAILURE
                        }
                    }
                }
            }
            CommandKind::Resume => {
                let interactive_io =
                    match make_interactive_io(&command.interactive_mode, command.bridge.as_ref()) {
                        Ok(interactive_io) => interactive_io,
                        Err(error) => {
                            eprintln!("error: {error}");
                            return ExitCode::FAILURE;
                        }
                    };
                let reporter = match make_run_status_reporter(command.bridge.as_ref()) {
                    Ok(reporter) => reporter,
                    Err(error) => {
                        eprintln!("error: {error}");
                        return ExitCode::FAILURE;
                    }
                };
                let resume_worker_cwd = resolve_worker_cwd(
                    &command.root,
                    command.bridge.as_ref(),
                    env::current_dir().ok(),
                );

                let timeout = Duration::from_secs(command.timeout_secs.unwrap_or(900));

                if command.real_adapters {
                    let script = match find_compose_script() {
                        Ok(p) => p,
                        Err(e) => {
                            eprintln!("error: {e}");
                            return ExitCode::FAILURE;
                        }
                    };
                    let codex = match find_codex_binary() {
                        Ok(p) => p,
                        Err(e) => {
                            eprintln!("error: {e}");
                            return ExitCode::FAILURE;
                        }
                    };
                    let config = match AdapterConfig::new(
                        script,
                        codex,
                        resume_worker_cwd,
                        timeout,
                        Duration::from_secs(5),
                    ) {
                        Ok(c) => c,
                        Err(e) => {
                            eprintln!("adapter config error: {e}");
                            return ExitCode::FAILURE;
                        }
                    };
                    let prompt_builder = ShellPromptBuilder::new(config.clone());
                    let dispatcher = CodexWorkerDispatcher::with_reporter(config, reporter.clone());
                    match resume_run_with_reporter(
                        &command.root,
                        &prompt_builder,
                        &dispatcher,
                        interactive_io.as_ref(),
                        reporter.as_ref(),
                    ) {
                        Ok(state) => {
                            println!("resume complete: run_id={}", state.run_id);
                            println!("status: {:?}", state.status);
                            println!(
                                "phases: {}",
                                state.phases.keys().cloned().collect::<Vec<_>>().join(", ")
                            );
                            ExitCode::SUCCESS
                        }
                        Err(e) => {
                            eprintln!("error: {e}");
                            ExitCode::FAILURE
                        }
                    }
                } else {
                    let prompt_builder = FakePromptBuilder;
                    let dispatcher = FakeWorkerDispatcher;
                    match resume_run_with_reporter(
                        &command.root,
                        &prompt_builder,
                        &dispatcher,
                        interactive_io.as_ref(),
                        reporter.as_ref(),
                    ) {
                        Ok(state) => {
                            println!("resume complete: run_id={}", state.run_id);
                            println!("status: {:?}", state.status);
                            println!(
                                "phases: {}",
                                state.phases.keys().cloned().collect::<Vec<_>>().join(", ")
                            );
                            ExitCode::SUCCESS
                        }
                        Err(e) => {
                            eprintln!("error: {e}");
                            ExitCode::FAILURE
                        }
                    }
                }
            }
        },
        Err(message) => {
            eprintln!("{message}");
            eprintln!();
            eprintln!("{}", usage());
            ExitCode::FAILURE
        }
    }
}

fn parse_cli<I>(args: I) -> Result<Command, String>
where
    I: IntoIterator<Item = OsString>,
{
    let mut args = args.into_iter();
    let _program = args.next();

    let subcommand = args
        .next()
        .ok_or_else(|| "missing subcommand".to_string())?;
    let subcommand = subcommand
        .into_string()
        .map_err(|_| "subcommand must be valid UTF-8".to_string())?;
    // Handle --help / -h / help as a top-level subcommand
    if matches!(subcommand.as_str(), "--help" | "-h" | "help") {
        return Err("help requested".to_string());
    }

    let kind = CommandKind::parse(&subcommand)
        .ok_or_else(|| format!("unsupported subcommand: {subcommand}"))?;

    let ParsedOptions {
        definition,
        method_id,
        root,
        real_adapters,
        interactive_mode,
        bridge_run_id,
        bridge_project_path,
        timeout_secs,
    } = parse_options(args)?;
    let root = root.ok_or_else(|| format!("missing required --root for {}", kind.as_str()))?;

    if bridge_project_path.is_some() && bridge_run_id.is_none() {
        return Err("--bridge-project-path requires --bridge-run-id".to_string());
    }

    // Resolve definition: --definition takes precedence, --method-id materializes a built-in
    let definition = if let Some(def) = definition {
        Some(def)
    } else if let Some(ref mid) = method_id {
        if matches!(kind, CommandKind::Normalize | CommandKind::Run) {
            Some(materialize_builtin_method(mid, &root)?)
        } else {
            None
        }
    } else {
        None
    };

    if matches!(kind, CommandKind::Normalize | CommandKind::Run) && definition.is_none() {
        return Err(format!(
            "missing --definition or --method-id for {}",
            kind.as_str()
        ));
    }

    let bridge = bridge_run_id.map(|run_id| BridgeOptions {
        run_id,
        project_path: bridge_project_path.unwrap_or_else(|| root.clone()),
    });

    Ok(Command {
        kind,
        definition,
        root,
        real_adapters,
        interactive_mode,
        bridge,
        timeout_secs,
    })
}

fn parse_options<I>(args: I) -> Result<ParsedOptions, String>
where
    I: IntoIterator<Item = OsString>,
{
    let mut parsed = ParsedOptions::default();
    let mut args = args.into_iter();

    while let Some(flag) = args.next() {
        let flag = flag
            .into_string()
            .map_err(|_| "arguments must be valid UTF-8".to_string())?;

        match flag.as_str() {
            "--definition" => {
                let value = next_path_value(&mut args, "--definition")?;
                parsed.definition = Some(value);
            }
            "--method-id" => {
                parsed.method_id = Some(next_string_value(&mut args, "--method-id")?);
            }
            "--root" => {
                let value = next_path_value(&mut args, "--root")?;
                parsed.root = Some(value);
            }
            "--real" => {
                parsed.real_adapters = true;
            }
            "--approve" => {
                parsed.interactive_mode = InteractiveMode::AutoApprove;
            }
            "--reject" => {
                parsed.interactive_mode = InteractiveMode::AutoReject;
            }
            "--response-dir" => {
                let value = next_path_value(&mut args, "--response-dir")?;
                parsed.interactive_mode = InteractiveMode::ResponseDir(value);
            }
            "--bridge-run-id" => {
                parsed.bridge_run_id = Some(next_string_value(&mut args, "--bridge-run-id")?);
            }
            "--bridge-project-path" => {
                parsed.bridge_project_path =
                    Some(next_path_value(&mut args, "--bridge-project-path")?);
            }
            "--timeout" => {
                let value = next_string_value(&mut args, "--timeout")?;
                parsed.timeout_secs =
                    Some(value.parse::<u64>().map_err(|_| {
                        format!("--timeout must be a positive integer, got '{value}'")
                    })?);
            }
            "--help" | "-h" | "help" => return Err("help requested".to_string()),
            _ => return Err(format!("unrecognized argument: {flag}")),
        }
    }

    Ok(parsed)
}

fn next_path_value<I>(args: &mut I, flag: &str) -> Result<PathBuf, String>
where
    I: Iterator<Item = OsString>,
{
    let value = args
        .next()
        .ok_or_else(|| format!("missing value for {flag}"))?;
    Ok(PathBuf::from(value))
}

fn next_string_value<I>(args: &mut I, flag: &str) -> Result<String, String>
where
    I: Iterator<Item = OsString>,
{
    args.next()
        .ok_or_else(|| format!("missing value for {flag}"))?
        .into_string()
        .map_err(|_| format!("{flag} must be valid UTF-8"))
}

/// Find compose-prompt.sh: check COMPOSE_SCRIPT_PATH env, then relative to cargo manifest.
fn find_compose_script() -> Result<PathBuf, String> {
    if let Ok(path) = env::var("COMPOSE_SCRIPT_PATH") {
        let p = PathBuf::from(path);
        if p.exists() {
            return Ok(p);
        }
    }
    // Relative to project root: scripts/relay/compose-prompt.sh
    let candidates = [
        PathBuf::from("scripts/relay/compose-prompt.sh"),
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../scripts/relay/compose-prompt.sh"),
    ];
    for c in &candidates {
        if let Ok(canonical) = c.canonicalize() {
            return Ok(canonical);
        }
    }
    Err("cannot find compose-prompt.sh (set COMPOSE_SCRIPT_PATH)".into())
}

/// Find codex binary: check CODEX_PATH env, then `which codex`.
fn find_codex_binary() -> Result<PathBuf, String> {
    if let Ok(path) = env::var("CODEX_PATH") {
        let p = PathBuf::from(path);
        if p.exists() {
            return Ok(p);
        }
    }
    // Try `which codex`
    let output = std::process::Command::new("which")
        .arg("codex")
        .output()
        .map_err(|e| format!("failed to run `which codex`: {e}"))?;
    if output.status.success() {
        let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !path.is_empty() {
            return Ok(PathBuf::from(path));
        }
    }
    Err("cannot find codex binary (set CODEX_PATH)".into())
}

fn make_interactive_io(
    mode: &InteractiveMode,
    bridge: Option<&BridgeOptions>,
) -> Result<Box<dyn capacitor_core::method_runner::adapters::InteractiveIO>, String> {
    let fallback = match mode {
        InteractiveMode::AutoApprove => Box::new(FakeInteractiveIO::new("approved"))
            as Box<dyn capacitor_core::method_runner::adapters::InteractiveIO>,
        InteractiveMode::AutoReject => Box::new(FakeInteractiveIO::new("rejected"))
            as Box<dyn capacitor_core::method_runner::adapters::InteractiveIO>,
        InteractiveMode::ResponseDir(dir) => Box::new(FileInteractiveIO::new(dir.clone()))
            as Box<dyn capacitor_core::method_runner::adapters::InteractiveIO>,
    };

    let Some(bridge) = bridge else {
        return Ok(fallback);
    };

    let (home_dir, endpoint) = discover_runtime_service_endpoint()?;
    Ok(Box::new(BridgeInteractiveIO::new(
        endpoint,
        bridge.project_path.clone(),
        bridge.run_id.clone(),
        home_dir,
        fallback,
    )))
}

fn discover_runtime_service_endpoint() -> Result<(PathBuf, RuntimeServiceEndpoint), String> {
    let home_dir = dirs::home_dir()
        .ok_or_else(|| "bridge mode requires a detectable home directory".to_string())?;
    let endpoint = RuntimeServiceEndpoint::discover(&home_dir, RUNTIME_SERVICE_DEFAULT_PORT)?
        .ok_or_else(|| "bridge mode requires a reachable runtime service bootstrap".to_string())?;
    Ok((home_dir, endpoint))
}

fn make_run_status_reporter(
    bridge: Option<&BridgeOptions>,
) -> Result<Arc<dyn RunStatusReporter + Send + Sync>, String> {
    let Some(bridge) = bridge else {
        return Ok(Arc::new(NoopRunStatusReporter));
    };

    let (_home_dir, endpoint) = discover_runtime_service_endpoint()?;
    Ok(Arc::new(RuntimeRunStatusReporter::new(
        endpoint,
        bridge.project_path.clone(),
        bridge.run_id.clone(),
    )))
}

fn usage() -> &'static str {
    "Usage:
  method-runner normalize --definition <path> --root <path>
  method-runner run       (--definition <path> | --method-id <id>) --root <path> [--real] [--timeout <seconds>] [--approve|--reject|--response-dir <path>] [--bridge-run-id <run-id>] [--bridge-project-path <path>]
  method-runner resume    --root <path> [--real] [--timeout <seconds>] [--approve|--reject|--response-dir <path>] [--bridge-run-id <run-id>] [--bridge-project-path <path>]

Flags:
  --definition           Path to a YAML method definition file
  --method-id            Built-in method id (execution_only, shape_and_execute, deep_debug, greenfield_build)
  --real                 Use real subprocess adapters (ShellPromptBuilder + CodexWorkerDispatcher)
  --timeout              Worker dispatch timeout in seconds (default: 900)
  --approve              Auto-approve all interactive checkpoints (default)
  --reject               Auto-reject all interactive checkpoints
  --response-dir         Read checkpoint responses from JSON files in <path>
  --bridge-run-id        Enable runtime-service bridge mode for the given run id
  --bridge-project-path  Override the bridge project path (defaults to --root)"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn worker_cwd_prefers_bridge_project_path_over_current_dir_and_root() {
        let root = PathBuf::from("/tmp/run-root");
        let bridge = BridgeOptions {
            run_id: "run-123".to_string(),
            project_path: PathBuf::from("/tmp/project-root"),
        };

        let resolved = resolve_worker_cwd(
            &root,
            Some(&bridge),
            Some(PathBuf::from("/tmp/current-dir")),
        );

        assert_eq!(resolved, PathBuf::from("/tmp/project-root"));
    }

    #[test]
    fn worker_cwd_uses_current_dir_when_bridge_is_absent() {
        let root = PathBuf::from("/tmp/run-root");

        let resolved = resolve_worker_cwd(&root, None, Some(PathBuf::from("/tmp/current-dir")));

        assert_eq!(resolved, PathBuf::from("/tmp/current-dir"));
    }

    #[test]
    fn worker_cwd_falls_back_to_execution_root_without_bridge_or_current_dir() {
        let root = PathBuf::from("/tmp/run-root");

        let resolved = resolve_worker_cwd(&root, None, None);

        assert_eq!(resolved, root);
    }

    #[test]
    fn parse_cli_timeout_flag_sets_timeout_secs() {
        let temp = tempfile::tempdir().expect("tempdir");
        let root = temp.path().join("run-root");

        let command = parse_cli([
            OsString::from("method-runner"),
            OsString::from("run"),
            OsString::from("--method-id"),
            OsString::from("execution_only"),
            OsString::from("--root"),
            root.as_os_str().to_os_string(),
            OsString::from("--timeout"),
            OsString::from("1800"),
        ])
        .expect("parse command");

        assert_eq!(command.timeout_secs, Some(1800));
    }

    #[test]
    fn parse_cli_omitted_timeout_defaults_to_none() {
        let temp = tempfile::tempdir().expect("tempdir");
        let root = temp.path().join("run-root");

        let command = parse_cli([
            OsString::from("method-runner"),
            OsString::from("run"),
            OsString::from("--method-id"),
            OsString::from("execution_only"),
            OsString::from("--root"),
            root.as_os_str().to_os_string(),
        ])
        .expect("parse command");

        assert_eq!(command.timeout_secs, None);
    }

    #[test]
    fn parse_cli_preserves_bridge_project_override_for_run_commands() {
        let temp = tempfile::tempdir().expect("tempdir");
        let root = temp.path().join("run-root");
        let project = temp.path().join("project-root");
        std::fs::create_dir_all(&project).expect("project dir");

        let command = parse_cli([
            OsString::from("method-runner"),
            OsString::from("run"),
            OsString::from("--method-id"),
            OsString::from("execution_only"),
            OsString::from("--root"),
            root.as_os_str().to_os_string(),
            OsString::from("--bridge-run-id"),
            OsString::from("run-123"),
            OsString::from("--bridge-project-path"),
            project.as_os_str().to_os_string(),
        ])
        .expect("parse command");

        let bridge = command.bridge.expect("bridge options");
        assert_eq!(bridge.run_id, "run-123");
        assert_eq!(bridge.project_path, project);
    }
}
