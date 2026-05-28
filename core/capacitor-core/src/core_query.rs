use super::*;

#[uniffi::export]
impl CoreRuntime {
    pub fn app_snapshot(&self) -> Result<AppSnapshot, CoreRuntimeError> {
        let state = self.lock_state()?;
        let mut snapshot = state.snapshot();
        snapshot.change_version = self.version.load(Ordering::Relaxed);
        Ok(snapshot)
    }

    pub fn resolve_routing(
        &self,
        command: ResolveRoutingCommand,
    ) -> Result<RoutingView, CoreRuntimeError> {
        let state = self.lock_state()?;
        Ok(state.resolve_routing(command))
    }

    pub fn list_builtin_methods(&self) -> Vec<domain::MethodTemplate> {
        domain::method_registry::builtin_methods()
    }

    pub fn find_builtin_method(&self, method_id: String) -> Option<domain::MethodTemplate> {
        domain::method_registry::find_method(&method_id)
    }

    pub fn load_dashboard(&self) -> Result<DashboardData, CoreRuntimeError> {
        let settings_path = self.app_storage.claude_root().join("settings.json");
        let instructions_path = self.app_storage.claude_root().join("CLAUDE.md");

        let skills_dir = resolve_symlink(&self.app_storage.claude_root().join("skills"));
        let commands_dir = resolve_symlink(&self.app_storage.claude_root().join("commands"));
        let agents_dir = resolve_symlink(&self.app_storage.claude_root().join("agents"));

        let global = GlobalConfig {
            settings_path: settings_path.to_string_lossy().to_string(),
            settings_exists: settings_path.exists(),
            instructions_path: if instructions_path.exists() {
                Some(instructions_path.to_string_lossy().to_string())
            } else {
                None
            },
            skills_dir: skills_dir.as_ref().map(|p| p.to_string_lossy().to_string()),
            commands_dir: commands_dir
                .as_ref()
                .map(|p| p.to_string_lossy().to_string()),
            agents_dir: agents_dir.as_ref().map(|p| p.to_string_lossy().to_string()),
            skill_count: skills_dir
                .as_ref()
                .map(|d| count_artifacts_in_dir(d, "skills"))
                .unwrap_or(0),
            command_count: commands_dir
                .as_ref()
                .map(|d| count_artifacts_in_dir(d, "commands"))
                .unwrap_or(0),
            agent_count: agents_dir
                .as_ref()
                .map(|d| count_artifacts_in_dir(d, "agents"))
                .unwrap_or(0),
        };

        let plugins = self.list_plugins_internal().unwrap_or_default();
        let projects = load_projects_with_storage(&self.app_storage).unwrap_or_default();

        Ok(DashboardData {
            global,
            plugins,
            projects,
        })
    }

    pub fn get_suggested_projects(&self) -> Result<Vec<SuggestedProject>, CoreRuntimeError> {
        let projects_dir = self.app_storage.claude_root().join("projects");
        if !projects_dir.exists() {
            return Ok(Vec::new());
        }

        let config = load_hud_config_with_storage(&self.app_storage);
        let pinned_set: std::collections::HashSet<_> = config.pinned_projects.iter().collect();

        let mut suggestions: Vec<(SuggestedProject, u32)> = Vec::new();

        if let Ok(entries) = fs_err::read_dir(&projects_dir) {
            for entry in entries.filter_map(|e| e.ok()).take(200) {
                if !entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                    continue;
                }

                let encoded_name = entry.file_name().to_string_lossy().to_string();
                if let Some(real_path) = runtime::projects::try_resolve_encoded_path(&encoded_name)
                {
                    if pinned_set.contains(&real_path) {
                        continue;
                    }

                    let project_path = PathBuf::from(&real_path);

                    if let Ok(home) = std::env::var("HOME") {
                        if real_path == home {
                            continue;
                        }
                    }

                    let is_child_of_pinned = config
                        .pinned_projects
                        .iter()
                        .any(|pinned| project_path.starts_with(pinned));
                    if is_child_of_pinned {
                        continue;
                    }

                    let has_indicators = has_project_indicators(&project_path);
                    let has_claude_md = project_path.join("CLAUDE.md").exists();

                    if !has_indicators && !has_claude_md {
                        continue;
                    }

                    let task_count = fs_err::read_dir(entry.path())
                        .map(|entries| {
                            entries
                                .filter_map(|e| e.ok())
                                .take(100)
                                .filter(|e| e.path().extension().is_some_and(|ext| ext == "jsonl"))
                                .count() as u32
                        })
                        .unwrap_or(0);

                    let display_path = if real_path.starts_with("/Users/") {
                        format!(
                            "~/{}",
                            real_path.split('/').skip(3).collect::<Vec<_>>().join("/")
                        )
                    } else {
                        real_path.clone()
                    };

                    let name = real_path
                        .split('/')
                        .next_back()
                        .unwrap_or(&real_path)
                        .to_string();

                    suggestions.push((
                        SuggestedProject {
                            path: real_path,
                            display_path,
                            name,
                            task_count,
                            has_claude_md,
                            has_project_indicators: has_indicators,
                        },
                        task_count,
                    ));
                }
            }
        }

        suggestions.sort_by_key(|(_, task_count)| std::cmp::Reverse(*task_count));
        Ok(suggestions.into_iter().take(8).map(|(s, _)| s).collect())
    }

    pub fn get_project_status(
        &self,
        project_path: String,
    ) -> Result<Option<ProjectStatus>, CoreRuntimeError> {
        Ok(runtime::sessions::read_project_status(&project_path))
    }

    pub fn load_ideas(
        &self,
        project_path: String,
    ) -> Result<Vec<runtime::types::Idea>, CoreRuntimeError> {
        runtime::ideas::load_ideas_with_storage(&self.app_storage, &project_path)
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn load_ideas_order(&self, project_path: String) -> Result<Vec<String>, CoreRuntimeError> {
        runtime::ideas::load_ideas_order_with_storage(&self.app_storage, &project_path)
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn get_ideas_file_path(&self, project_path: String) -> String {
        self.app_storage
            .project_ideas_file(&project_path)
            .to_string_lossy()
            .to_string()
    }
}
