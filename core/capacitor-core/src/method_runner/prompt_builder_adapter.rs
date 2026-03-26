//! Real ShellPromptBuilder — wraps `compose-prompt.sh` as a subprocess.
//!
//! This adapter writes the header file, preflights skill/template paths,
//! spawns the compose-prompt script, and captures stderr + metadata.

use std::path::PathBuf;
use std::process::Command;
use std::time::Instant;

use crate::method_runner::adapter_config::{
    build_allowed_env, write_preflight_if_needed, AdapterConfig,
};
use crate::method_runner::adapters::{
    AdapterError, PromptBuildRequest, PromptBuildResult, PromptBuilder,
};

// ---------------------------------------------------------------------------
// ShellPromptBuilder
// ---------------------------------------------------------------------------

/// Real prompt builder that delegates to `compose-prompt.sh`.
pub struct ShellPromptBuilder {
    config: AdapterConfig,
}

impl ShellPromptBuilder {
    pub fn new(config: AdapterConfig) -> Self {
        Self { config }
    }

    /// Resolve skill name → absolute path to SKILL.md under the HOME-based skill dir.
    fn skill_path(skill: &str) -> PathBuf {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        PathBuf::from(home)
            .join(".claude/skills")
            .join(skill)
            .join("SKILL.md")
    }

    /// Resolve template name → absolute path to template file under the HOME-based dir.
    fn template_path(template: &str) -> PathBuf {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        PathBuf::from(home)
            .join(".claude/skills/manage-codex/references")
            .join(format!("{}-template.md", template))
    }
}

impl PromptBuilder for ShellPromptBuilder {
    fn build_prompt(
        &self,
        request: &PromptBuildRequest,
    ) -> Result<PromptBuildResult, AdapterError> {
        // Write preflight record on first call
        write_preflight_if_needed(&request.relay_root, &self.config)
            .map_err(AdapterError::IoError)?;

        // Ensure relay root exists
        std::fs::create_dir_all(&request.relay_root)?;

        let adapter_dir = request.relay_root.join("adapter");
        std::fs::create_dir_all(&adapter_dir)?;

        // 1. Preflight skill paths
        for skill in &request.skills {
            let path = Self::skill_path(skill);
            if !path.exists() {
                return Err(AdapterError::SkillNotFound(format!(
                    "skill '{}' not found at {}",
                    skill,
                    path.display()
                )));
            }
        }

        // 2. Preflight template path
        if let Some(ref template) = request.template {
            let path = Self::template_path(template);
            if !path.exists() {
                return Err(AdapterError::TemplateNotFound(format!(
                    "template '{}' not found at {}",
                    template,
                    path.display()
                )));
            }
        }

        // 3. Write header file (with optional task context from context.json)
        let header_path = request.relay_root.join("prompt-header.md");
        let context_prefix = request
            .context_file
            .as_ref()
            .and_then(|path| {
                std::fs::read_to_string(path)
                    .map_err(|e| {
                        eprintln!(
                            "warning: failed to read context file {}: {}",
                            path.display(),
                            e
                        );
                        e
                    })
                    .ok()
            })
            .and_then(|json| {
                serde_json::from_str::<serde_json::Value>(&json)
                    .map_err(|e| {
                        eprintln!("warning: failed to parse context.json: {}", e);
                        e
                    })
                    .ok()
            })
            .map(|v| {
                let title = v["title"].as_str().unwrap_or("");
                let desc = v["description"].as_str().unwrap_or("");
                if title.is_empty() && desc.is_empty() {
                    String::new()
                } else if desc.is_empty() {
                    format!("# Task: {}\n\n", title)
                } else {
                    format!("# Task: {}\n\n{}\n\n", title, desc)
                }
            })
            .unwrap_or_default();

        let header_content = format!(
            "{}# Step: {}\nPhase: {}\nAttempt: {}\n\n{}\n",
            context_prefix,
            request.step_id,
            request.phase_id,
            request.attempt,
            request.instructions
        );
        std::fs::write(&header_path, &header_content)?;

        // 4. Build argv
        let prompt_path = request.relay_root.join("prompt.md");
        let script_path = &self.config.script_path;

        let mut args: Vec<String> = vec![
            "--header".into(),
            header_path.to_string_lossy().into_owned(),
            "--out".into(),
            prompt_path.to_string_lossy().into_owned(),
        ];

        if !request.skills.is_empty() {
            args.push("--skills".into());
            args.push(request.skills.join(","));
        }

        if let Some(ref template) = request.template {
            args.push("--template".into());
            args.push(template.clone());
        }

        // Always pass relay_root for token substitution
        args.push("--root".into());
        args.push(request.relay_root.to_string_lossy().into_owned());

        // 5. Spawn with allowlisted env + adapter overrides
        let overrides: Vec<(&str, &str)> = self
            .config
            .env_overrides
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        let env = build_allowed_env(&overrides);

        let start = Instant::now();
        let output = Command::new("bash")
            .arg(script_path.to_string_lossy().as_ref())
            .args(&args)
            .env_clear()
            .envs(env.iter().map(|(k, v)| (k.as_str(), v.as_str())))
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .output()
            .map_err(|e| {
                AdapterError::SpawnFailed(format!("compose-prompt spawn failed: {}", e))
            })?;

        let elapsed = start.elapsed();

        // 6. Capture stderr
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        if !stderr.is_empty() {
            let stderr_path = adapter_dir.join("prompt-builder.stderr.log");
            let _ = std::fs::write(&stderr_path, &stderr);
        }

        // 7. Write metadata JSON
        let metadata = serde_json::json!({
            "argv": args,
            "cwd": std::env::current_dir().ok().map(|p| p.to_string_lossy().into_owned()),
            "exit_code": output.status.code(),
            "elapsed_ms": elapsed.as_millis(),
            "header_path": header_path.to_string_lossy(),
            "prompt_path": prompt_path.to_string_lossy(),
            "script_path": script_path.to_string_lossy(),
        });
        let _ = std::fs::write(
            adapter_dir.join("prompt-builder.metadata.json"),
            serde_json::to_string_pretty(&metadata).unwrap_or_default(),
        );

        // 8. Check exit code
        if !output.status.success() {
            let exit_code = output.status.code().unwrap_or(-1);
            return Err(AdapterError::AssemblyFailed {
                exit_code,
                stderr: stderr.trim().to_string(),
            });
        }

        // 9. Enforce prompt output existence on exit 0
        if !prompt_path.exists() {
            return Err(AdapterError::ContractViolation(
                "compose-prompt exited 0 but prompt.md does not exist".into(),
            ));
        }

        Ok(PromptBuildResult {
            header_path,
            prompt_path,
        })
    }
}
