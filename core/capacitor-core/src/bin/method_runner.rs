use std::env;
use std::ffi::OsString;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use capacitor_core::method_runner::adapter_config::AdapterConfig;
use capacitor_core::method_runner::adapters::{
    FakeInteractiveIO, FakePromptBuilder, FakeWorkerDispatcher, FileInteractiveIO,
};
use capacitor_core::method_runner::definition::DefinitionSource;
use capacitor_core::method_runner::executor::{execute_normalize, execute_run};
use capacitor_core::method_runner::prompt_builder_adapter::ShellPromptBuilder;
use capacitor_core::method_runner::resume::resume_run;
use capacitor_core::method_runner::worker_dispatch_adapter::CodexWorkerDispatcher;

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
    root: Option<PathBuf>,
    real_adapters: bool,
    interactive_mode: InteractiveMode,
}

#[derive(Debug)]
struct Command {
    kind: CommandKind,
    definition: Option<PathBuf>,
    root: PathBuf,
    real_adapters: bool,
    interactive_mode: InteractiveMode,
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
                let interactive_io = make_interactive_io(&command.interactive_mode);
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
                        command.root.clone(),
                        Duration::from_secs(300),
                        Duration::from_secs(5),
                    ) {
                        Ok(c) => c,
                        Err(e) => {
                            eprintln!("adapter config error: {e}");
                            return ExitCode::FAILURE;
                        }
                    };
                    let prompt_builder = ShellPromptBuilder::new(config.clone());
                    let dispatcher = CodexWorkerDispatcher::new(config);
                    match execute_run(
                        &source,
                        &prompt_builder,
                        &dispatcher,
                        interactive_io.as_ref(),
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
                    match execute_run(
                        &source,
                        &prompt_builder,
                        &dispatcher,
                        interactive_io.as_ref(),
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
                let interactive_io = make_interactive_io(&command.interactive_mode);
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
                        command.root.clone(),
                        Duration::from_secs(300),
                        Duration::from_secs(5),
                    ) {
                        Ok(c) => c,
                        Err(e) => {
                            eprintln!("adapter config error: {e}");
                            return ExitCode::FAILURE;
                        }
                    };
                    let prompt_builder = ShellPromptBuilder::new(config.clone());
                    let dispatcher = CodexWorkerDispatcher::new(config);
                    match resume_run(
                        &command.root,
                        &prompt_builder,
                        &dispatcher,
                        interactive_io.as_ref(),
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
                    match resume_run(
                        &command.root,
                        &prompt_builder,
                        &dispatcher,
                        interactive_io.as_ref(),
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

    let options = parse_options(args)?;
    let root = options
        .root
        .ok_or_else(|| format!("missing required --root for {}", kind.as_str()))?;

    if matches!(kind, CommandKind::Normalize | CommandKind::Run) && options.definition.is_none() {
        return Err(format!(
            "missing required --definition for {}",
            kind.as_str()
        ));
    }

    Ok(Command {
        kind,
        definition: options.definition,
        root,
        real_adapters: options.real_adapters,
        interactive_mode: options.interactive_mode,
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
) -> Box<dyn capacitor_core::method_runner::adapters::InteractiveIO> {
    match mode {
        InteractiveMode::AutoApprove => Box::new(FakeInteractiveIO::new("approved")),
        InteractiveMode::AutoReject => Box::new(FakeInteractiveIO::new("rejected")),
        InteractiveMode::ResponseDir(dir) => Box::new(FileInteractiveIO::new(dir.clone())),
    }
}

fn usage() -> &'static str {
    "Usage:
  method-runner normalize --definition <path> --root <path>
  method-runner run       --definition <path> --root <path> [--real] [--approve|--reject|--response-dir <path>]
  method-runner resume    --root <path> [--real] [--approve|--reject|--response-dir <path>]

Flags:
  --real            Use real subprocess adapters (ShellPromptBuilder + CodexWorkerDispatcher)
  --approve         Auto-approve all interactive checkpoints (default)
  --reject          Auto-reject all interactive checkpoints
  --response-dir    Read checkpoint responses from JSON files in <path>"
}
