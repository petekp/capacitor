//! YAML definition loading and normalization for the method runner.
//!
//! This module owns the boundary between authored method YAML and the
//! frozen, fully-explicit definition used by runtime execution.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

// ---------------------------------------------------------------------------
// Raw (authored) YAML types — direct deserialization targets
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RawDefinitionFile {
    pub schema_version: String,
    pub method: RawMethodDefinition,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RawMethodDefinition {
    pub id: String,
    pub version: String,
    pub title: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub defaults: Option<RawMethodDefaults>,
    #[serde(default)]
    pub inputs: Option<BTreeMap<String, RawMethodInput>>,
    #[serde(default)]
    pub outputs: Option<BTreeMap<String, RawMethodOutput>>,
    pub phases: Vec<RawPhase>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RawMethodDefaults {
    #[serde(default)]
    pub skills: Option<Vec<String>>,
    #[serde(default)]
    pub template: Option<String>,
    #[serde(default)]
    pub max_attempts: Option<u32>,
    #[serde(default)]
    pub completion_policy: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RawMethodInput {
    #[serde(rename = "type")]
    pub input_type: String,
    #[serde(default)]
    pub required: Option<bool>,
    #[serde(default)]
    pub description: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RawMethodOutput {
    pub from: String,
    #[serde(default)]
    pub required: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RawPhase {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub execution: Option<String>,
    #[serde(default)]
    pub skills: Option<Vec<String>>,
    #[serde(default)]
    pub gate: Option<RawGate>,
    pub steps: Vec<RawStep>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RawStep {
    pub id: String,
    pub title: String,
    pub action: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub template: Option<String>,
    #[serde(default)]
    pub skills: Option<Vec<String>>,
    #[serde(default)]
    pub max_attempts: Option<u32>,
    #[serde(default)]
    pub completion_policy: Option<String>,
    #[serde(default)]
    pub inputs: Option<Vec<String>>,
    #[serde(default)]
    pub outputs: Option<BTreeMap<String, RawStepOutput>>,
    #[serde(default)]
    pub gate: Option<RawGate>,
    #[serde(default)]
    pub success: Option<String>,
    #[serde(default)]
    pub dispatch: Option<RawDispatchConfig>,
    #[serde(default)]
    pub interactive: Option<RawInteractiveConfig>,
    #[serde(default)]
    pub synthesis: Option<RawSynthesisConfig>,
    #[serde(default)]
    pub pipeline_execute: Option<RawPipelineExecuteConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RawStepOutput {
    pub path: String,
    #[serde(rename = "type")]
    pub output_type: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RawGate {
    pub id: String,
    #[serde(rename = "type")]
    pub gate_type: String,
    #[serde(default)]
    pub outputs: Option<Vec<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RawDispatchConfig {
    pub instructions: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RawInteractiveConfig {
    pub prompt: String,
    pub response_type: String,
    pub output: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RawSynthesisConfig {
    pub instructions: String,
    pub output: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RawPipelineExecuteConfig {
    pub pipeline: String,
    #[serde(default)]
    pub inputs: Option<BTreeMap<String, String>>,
    #[serde(default)]
    pub outputs: Option<BTreeMap<String, String>>,
}

// ---------------------------------------------------------------------------
// Normalized (frozen) types — fully resolved, no optionals for defaulted fields
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NormalizedDefinitionFile {
    pub schema_version: String,
    pub method: NormalizedMethodDefinition,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NormalizedMethodDefinition {
    pub id: String,
    pub version: String,
    pub title: String,
    pub description: String,
    pub inputs: BTreeMap<String, NormalizedInput>,
    pub outputs: BTreeMap<String, NormalizedOutput>,
    pub phases: Vec<NormalizedPhase>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NormalizedInput {
    pub input_type: String,
    pub required: bool,
    pub description: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NormalizedOutput {
    pub from: String,
    pub required: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NormalizedPhase {
    pub id: String,
    pub title: String,
    pub description: String,
    pub execution: ExecutionMode,
    pub skills: Vec<String>,
    pub gate: Option<NormalizedGate>,
    pub steps: Vec<NormalizedStep>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExecutionMode {
    Serial,
    Parallel,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NormalizedStep {
    pub id: String,
    pub title: String,
    pub action: ActionKind,
    pub description: String,
    pub template: Option<String>,
    pub skills: Vec<String>,
    pub max_attempts: u32,
    pub completion_policy: CompletionPolicy,
    pub inputs: Vec<String>,
    pub outputs: BTreeMap<String, NormalizedStepOutput>,
    pub gate: Option<NormalizedGate>,
    pub config: StepActionConfig,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionKind {
    Dispatch,
    Interactive,
    Synthesis,
    PipelineExecute,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CompletionPolicy {
    AllComplete,
    FirstClean,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NormalizedStepOutput {
    pub path: String,
    pub output_type: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NormalizedGate {
    pub id: String,
    pub gate_type: String,
    pub outputs: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum StepActionConfig {
    Dispatch {
        instructions: String,
    },
    Interactive {
        prompt: String,
        response_type: String,
        output: String,
    },
    Synthesis {
        instructions: String,
        output: String,
    },
    PipelineExecute {
        pipeline: String,
        inputs: BTreeMap<String, String>,
        outputs: BTreeMap<String, String>,
    },
    None,
}

// ---------------------------------------------------------------------------
// Step JSON — per-step metadata written to .method/steps/<phase>/<step>/step.json
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StepJson {
    pub phase_id: String,
    pub step_id: String,
    pub title: String,
    pub action: ActionKind,
    pub inputs: Vec<String>,
    pub outputs: BTreeMap<String, NormalizedStepOutput>,
    pub max_attempts: u32,
    pub completion_policy: CompletionPolicy,
    pub template: Option<String>,
    pub skills: Vec<String>,
}

// ---------------------------------------------------------------------------
// Source location
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DefinitionSource {
    pub definition_path: PathBuf,
    pub execution_root: PathBuf,
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

#[derive(Debug, thiserror::Error)]
pub enum NormalizationError {
    #[error("YAML parse error: {0}")]
    YamlParseError(#[from] serde_yaml::Error),

    #[error("unsupported schema_version '{version}' (expected '1')")]
    InvalidSchemaVersion { version: String },

    #[error("missing required field '{field}' in {context}")]
    MissingRequiredField { field: String, context: String },

    #[error("invalid action type '{action}' in step '{step_id}' (expected dispatch, interactive, synthesis, or pipeline-execute)")]
    InvalidActionType { action: String, step_id: String },

    #[error("invalid output locator '{locator}' in method output '{output_name}': expected format 'phase.step.output'")]
    InvalidLocator {
        locator: String,
        output_name: String,
    },

    #[error("duplicate phase id '{id}'")]
    DuplicatePhaseId { id: String },

    #[error("duplicate step id '{id}' in phase '{phase_id}'")]
    DuplicateStepId { id: String, phase_id: String },

    #[error("method output '{output_name}' references step output '{step_output}' in step '{phase_id}.{step_id}', but that step does not declare it")]
    UnresolvedOutputReference {
        output_name: String,
        phase_id: String,
        step_id: String,
        step_output: String,
    },

    #[error("method output '{output_name}' references phase '{phase_id}' which does not exist")]
    UnresolvedPhaseReference {
        output_name: String,
        phase_id: String,
    },

    #[error("method output '{output_name}' references step '{step_id}' which does not exist in phase '{phase_id}'")]
    UnresolvedStepReference {
        output_name: String,
        phase_id: String,
        step_id: String,
    },

    #[error("step '{step_id}' has action 'dispatch' but no dispatch config")]
    MissingActionConfig { step_id: String },

    #[error("I/O error: {0}")]
    IoError(#[from] std::io::Error),
}

// ---------------------------------------------------------------------------
// Normalizer
// ---------------------------------------------------------------------------

pub struct Normalizer;

impl Normalizer {
    /// Parse YAML source text and normalize into a fully-resolved definition.
    pub fn normalize(yaml_content: &str) -> Result<NormalizedDefinitionFile, NormalizationError> {
        let raw: RawDefinitionFile = serde_yaml::from_str(yaml_content)?;

        if raw.schema_version != "1" {
            return Err(NormalizationError::InvalidSchemaVersion {
                version: raw.schema_version,
            });
        }

        let defaults = raw.method.defaults.as_ref().cloned().unwrap_or_default();

        // Validate phase id uniqueness
        let mut phase_ids = BTreeSet::new();
        for phase in &raw.method.phases {
            if !phase_ids.insert(&phase.id) {
                return Err(NormalizationError::DuplicatePhaseId {
                    id: phase.id.clone(),
                });
            }
        }

        // Normalize phases
        let mut normalized_phases = Vec::new();
        for raw_phase in &raw.method.phases {
            let phase = Self::normalize_phase(raw_phase, &defaults)?;
            normalized_phases.push(phase);
        }

        // Validate method-level output locators
        let method_outputs = match &raw.method.outputs {
            Some(outputs) => {
                let mut normalized = BTreeMap::new();
                for (name, output) in outputs {
                    Self::validate_output_locator(name, &output.from, &normalized_phases)?;
                    normalized.insert(
                        name.clone(),
                        NormalizedOutput {
                            from: output.from.clone(),
                            required: output.required.unwrap_or(false),
                        },
                    );
                }
                normalized
            }
            None => BTreeMap::new(),
        };

        let method_inputs = match &raw.method.inputs {
            Some(inputs) => {
                let mut normalized = BTreeMap::new();
                for (name, input) in inputs {
                    normalized.insert(
                        name.clone(),
                        NormalizedInput {
                            input_type: input.input_type.clone(),
                            required: input.required.unwrap_or(false),
                            description: input.description.clone().unwrap_or_default(),
                        },
                    );
                }
                normalized
            }
            None => BTreeMap::new(),
        };

        Ok(NormalizedDefinitionFile {
            schema_version: "1".to_string(),
            method: NormalizedMethodDefinition {
                id: raw.method.id,
                version: raw.method.version,
                title: raw.method.title,
                description: raw.method.description.unwrap_or_default(),
                inputs: method_inputs,
                outputs: method_outputs,
                phases: normalized_phases,
            },
        })
    }

    fn normalize_phase(
        raw: &RawPhase,
        defaults: &RawMethodDefaults,
    ) -> Result<NormalizedPhase, NormalizationError> {
        let execution = match raw.execution.as_deref() {
            Some("parallel") => ExecutionMode::Parallel,
            _ => ExecutionMode::Serial,
        };

        // Phase-level skills merge with method defaults
        let phase_skills: Vec<String> = {
            let mut skills = defaults.skills.clone().unwrap_or_default();
            if let Some(ref ps) = raw.skills {
                for s in ps {
                    if !skills.contains(s) {
                        skills.push(s.clone());
                    }
                }
            }
            skills
        };

        // Validate step id uniqueness within phase
        let mut step_ids = BTreeSet::new();
        for step in &raw.steps {
            if !step_ids.insert(&step.id) {
                return Err(NormalizationError::DuplicateStepId {
                    id: step.id.clone(),
                    phase_id: raw.id.clone(),
                });
            }
        }

        let mut steps = Vec::new();
        for step in &raw.steps {
            steps.push(Self::normalize_step(step, defaults, &phase_skills)?);
        }

        let gate = raw.gate.as_ref().map(|g| NormalizedGate {
            id: g.id.clone(),
            gate_type: g.gate_type.clone(),
            outputs: g.outputs.clone().unwrap_or_default(),
        });

        Ok(NormalizedPhase {
            id: raw.id.clone(),
            title: raw.title.clone(),
            description: raw.description.clone().unwrap_or_default(),
            execution,
            skills: phase_skills,
            gate,
            steps,
        })
    }

    fn normalize_step(
        raw: &RawStep,
        defaults: &RawMethodDefaults,
        phase_skills: &[String],
    ) -> Result<NormalizedStep, NormalizationError> {
        let action = Self::parse_action_kind(&raw.action, &raw.id)?;

        // Template: step → method defaults (never inferred — I11, C2)
        let template = raw.template.clone().or_else(|| defaults.template.clone());

        // Skills: merge method defaults + phase + step (deduplicated)
        let skills = {
            let mut merged: Vec<String> = phase_skills.to_vec();
            if let Some(ref ss) = raw.skills {
                for s in ss {
                    if !merged.contains(s) {
                        merged.push(s.clone());
                    }
                }
            }
            merged
        };

        // max_attempts: step → method defaults → 1
        let max_attempts = raw.max_attempts.or(defaults.max_attempts).unwrap_or(1);

        // completion_policy: step → method defaults → all_complete
        let completion_policy = {
            let policy_str = raw
                .completion_policy
                .as_deref()
                .or(defaults.completion_policy.as_deref())
                .unwrap_or("all_complete");
            match policy_str {
                "first_clean" | "first-clean" => CompletionPolicy::FirstClean,
                _ => CompletionPolicy::AllComplete,
            }
        };

        let outputs = match &raw.outputs {
            Some(o) => o
                .iter()
                .map(|(k, v)| {
                    (
                        k.clone(),
                        NormalizedStepOutput {
                            path: v.path.clone(),
                            output_type: v.output_type.clone(),
                        },
                    )
                })
                .collect(),
            None => BTreeMap::new(),
        };

        let config = Self::build_action_config(action, raw)?;

        let gate = raw.gate.as_ref().map(|g| NormalizedGate {
            id: g.id.clone(),
            gate_type: g.gate_type.clone(),
            outputs: g.outputs.clone().unwrap_or_default(),
        });

        Ok(NormalizedStep {
            id: raw.id.clone(),
            title: raw.title.clone(),
            action,
            description: raw.description.clone().unwrap_or_default(),
            template,
            skills,
            max_attempts,
            completion_policy,
            inputs: raw.inputs.clone().unwrap_or_default(),
            outputs,
            gate,
            config,
        })
    }

    fn parse_action_kind(action: &str, step_id: &str) -> Result<ActionKind, NormalizationError> {
        match action {
            "dispatch" => Ok(ActionKind::Dispatch),
            "interactive" => Ok(ActionKind::Interactive),
            "synthesis" => Ok(ActionKind::Synthesis),
            "pipeline-execute" => Ok(ActionKind::PipelineExecute),
            _ => Err(NormalizationError::InvalidActionType {
                action: action.to_string(),
                step_id: step_id.to_string(),
            }),
        }
    }

    fn build_action_config(
        action: ActionKind,
        raw: &RawStep,
    ) -> Result<StepActionConfig, NormalizationError> {
        match action {
            ActionKind::Dispatch => {
                let cfg = raw.dispatch.as_ref().ok_or_else(|| {
                    NormalizationError::MissingActionConfig {
                        step_id: raw.id.clone(),
                    }
                })?;
                Ok(StepActionConfig::Dispatch {
                    instructions: cfg.instructions.clone(),
                })
            }
            ActionKind::Interactive => {
                let cfg = raw.interactive.as_ref().ok_or_else(|| {
                    NormalizationError::MissingActionConfig {
                        step_id: raw.id.clone(),
                    }
                })?;
                Ok(StepActionConfig::Interactive {
                    prompt: cfg.prompt.clone(),
                    response_type: cfg.response_type.clone(),
                    output: cfg.output.clone(),
                })
            }
            ActionKind::Synthesis => {
                let cfg = raw.synthesis.as_ref().ok_or_else(|| {
                    NormalizationError::MissingActionConfig {
                        step_id: raw.id.clone(),
                    }
                })?;
                Ok(StepActionConfig::Synthesis {
                    instructions: cfg.instructions.clone(),
                    output: cfg.output.clone(),
                })
            }
            ActionKind::PipelineExecute => {
                let cfg = raw.pipeline_execute.as_ref().ok_or_else(|| {
                    NormalizationError::MissingActionConfig {
                        step_id: raw.id.clone(),
                    }
                })?;
                Ok(StepActionConfig::PipelineExecute {
                    pipeline: cfg.pipeline.clone(),
                    inputs: cfg.inputs.clone().unwrap_or_default(),
                    outputs: cfg.outputs.clone().unwrap_or_default(),
                })
            }
        }
    }

    fn validate_output_locator(
        output_name: &str,
        locator: &str,
        phases: &[NormalizedPhase],
    ) -> Result<(), NormalizationError> {
        let segments: Vec<&str> = locator.split('.').collect();
        if segments.len() < 3 {
            return Err(NormalizationError::InvalidLocator {
                locator: locator.to_string(),
                output_name: output_name.to_string(),
            });
        }

        let phase_id = segments[0];
        let step_id = segments[1];
        // Last segment is the output name; middle segments (if 4-seg) include worker
        let step_output_name = segments.last().unwrap();

        let phase = phases.iter().find(|p| p.id == phase_id).ok_or_else(|| {
            NormalizationError::UnresolvedPhaseReference {
                output_name: output_name.to_string(),
                phase_id: phase_id.to_string(),
            }
        })?;

        let step = phase
            .steps
            .iter()
            .find(|s| s.id == step_id)
            .ok_or_else(|| NormalizationError::UnresolvedStepReference {
                output_name: output_name.to_string(),
                phase_id: phase_id.to_string(),
                step_id: step_id.to_string(),
            })?;

        if !step.outputs.contains_key(*step_output_name) {
            return Err(NormalizationError::UnresolvedOutputReference {
                output_name: output_name.to_string(),
                phase_id: phase_id.to_string(),
                step_id: step_id.to_string(),
                step_output: step_output_name.to_string(),
            });
        }

        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Definition Loader — reads from frozen snapshot only (I10)
// ---------------------------------------------------------------------------

pub struct DefinitionLoader;

impl DefinitionLoader {
    /// Load a normalized definition from a snapshot file.
    /// Enforces I10 (Definition Freeze): only reads from snapshot, never source YAML.
    pub fn load(snapshot_path: &Path) -> Result<NormalizedDefinitionFile, NormalizationError> {
        let content = std::fs::read_to_string(snapshot_path)?;
        let def: NormalizedDefinitionFile = serde_yaml::from_str(&content)?;
        Ok(def)
    }
}

// ---------------------------------------------------------------------------
// Snapshot + StepJson writing
// ---------------------------------------------------------------------------

pub fn write_snapshot(
    snapshot_path: &Path,
    definition: &NormalizedDefinitionFile,
) -> Result<(), NormalizationError> {
    if let Some(parent) = snapshot_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let yaml = serde_yaml::to_string(definition)?;
    std::fs::write(snapshot_path, yaml)?;
    Ok(())
}

pub fn write_step_json(
    step_dir: &Path,
    phase_id: &str,
    step: &NormalizedStep,
) -> Result<(), NormalizationError> {
    std::fs::create_dir_all(step_dir)?;
    let step_json = StepJson {
        phase_id: phase_id.to_string(),
        step_id: step.id.clone(),
        title: step.title.clone(),
        action: step.action,
        inputs: step.inputs.clone(),
        outputs: step.outputs.clone(),
        max_attempts: step.max_attempts,
        completion_policy: step.completion_policy,
        template: step.template.clone(),
        skills: step.skills.clone(),
    };
    let json = serde_json::to_string_pretty(&step_json).map_err(std::io::Error::other)?;
    std::fs::write(step_dir.join("step.json"), json)?;
    Ok(())
}
