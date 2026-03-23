use std::env;
use std::ffi::OsString;
use std::path::PathBuf;
use std::process::ExitCode;

use capacitor_core::method_runner::adapters::{
    FakeInteractiveIO, FakePromptBuilder, FakeWorkerDispatcher,
};
use capacitor_core::method_runner::definition::DefinitionSource;
use capacitor_core::method_runner::executor::{execute_normalize, execute_run};

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
struct ParsedOptions {
    definition: Option<PathBuf>,
    root: Option<PathBuf>,
}

#[derive(Debug)]
struct Command {
    kind: CommandKind,
    definition: Option<PathBuf>,
    root: PathBuf,
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
                    execution_root: command.root,
                };
                let prompt_builder = FakePromptBuilder;
                let dispatcher = FakeWorkerDispatcher;
                let interactive_io = FakeInteractiveIO {
                    response: "approved".to_string(),
                };
                match execute_run(&source, &prompt_builder, &dispatcher, &interactive_io) {
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
            CommandKind::Resume => {
                println!("resume not yet implemented");
                ExitCode::SUCCESS
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

fn usage() -> &'static str {
    "Usage:
  method-runner normalize --definition <path> --root <path>
  method-runner run --definition <path> --root <path>
  method-runner resume --root <path>"
}
