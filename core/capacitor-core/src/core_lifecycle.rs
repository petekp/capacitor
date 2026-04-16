use super::*;

#[uniffi::export]
impl CoreRuntime {
    #[uniffi::constructor]
    pub fn new() -> Result<Arc<Self>, CoreRuntimeError> {
        Self::from_storage(
            Arc::new(InMemorySnapshotStorage::default()),
            StorageConfig::default(),
        )
    }

    #[uniffi::constructor]
    pub fn new_with_snapshot_file(snapshot_file: String) -> Result<Arc<Self>, CoreRuntimeError> {
        let path = snapshot_file.trim();
        if path.is_empty() {
            return Err(CoreRuntimeError::from("snapshot_file path cannot be empty"));
        }

        let runtime = Self::from_storage_with_transcript_cold_start(
            Arc::new(JsonFileSnapshotStorage::new(path)),
            StorageConfig::default(),
        )?;

        let snapshot_path = PathBuf::from(path);
        if snapshot_path.exists() && runtime.app_snapshot()?.runs.is_empty() {
            eprintln!(
                "[capacitor-core] snapshot loaded with 0 runs from existing file: {}",
                snapshot_path.display()
            );
        }

        Ok(runtime)
    }

    pub fn claude_dir(&self) -> String {
        self.app_storage.claude_root().to_string_lossy().to_string()
    }

    pub fn capacitor_dir(&self) -> String {
        self.app_storage.root().to_string_lossy().to_string()
    }

    pub fn add_project(&self, path: String) -> Result<(), CoreRuntimeError> {
        let mut config = load_hud_config_with_storage(&self.app_storage);

        if !std::path::Path::new(&path).exists() {
            return Err(CoreRuntimeError::from(format!(
                "Path does not exist: {path}"
            )));
        }

        if config.pinned_projects.contains(&path) {
            return Err(CoreRuntimeError::from(format!(
                "Project already pinned: {path}"
            )));
        }

        config.pinned_projects.push(path);
        save_hud_config_with_storage(&self.app_storage, &config).map_err(CoreRuntimeError::from)
    }

    pub fn remove_project(&self, path: String) -> Result<(), CoreRuntimeError> {
        let mut config = load_hud_config_with_storage(&self.app_storage);
        config.pinned_projects.retain(|p| p != &path);
        save_hud_config_with_storage(&self.app_storage, &config).map_err(CoreRuntimeError::from)
    }

    pub fn validate_project(&self, path: String) -> Result<ValidationResultFfi, CoreRuntimeError> {
        let config = load_hud_config_with_storage(&self.app_storage);
        Ok(validate_project_path(&path, &config.pinned_projects).into())
    }

    pub fn create_project_claude_md(&self, project_path: String) -> Result<(), CoreRuntimeError> {
        create_claude_md(&project_path).map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn check_setup_status(&self) -> Result<SetupStatus, CoreRuntimeError> {
        Ok(self.setup_checker().check_setup_status())
    }

    pub fn check_dependency(&self, name: String) -> DependencyStatus {
        self.setup_checker().check_dependency(&name)
    }

    pub fn install_hook_binary_from_path(
        &self,
        source_path: String,
    ) -> Result<InstallResult, CoreRuntimeError> {
        self.setup_checker()
            .install_binary_from_path(&source_path)
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn install_hooks(&self) -> Result<InstallResult, CoreRuntimeError> {
        self.setup_checker()
            .install_hooks()
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn remove_hooks(&self) -> Result<InstallResult, CoreRuntimeError> {
        self.setup_checker()
            .remove_hooks()
            .map_err(|error| CoreRuntimeError::from(error.to_string()))
    }

    pub fn get_hook_status(&self) -> Result<HookStatus, CoreRuntimeError> {
        Ok(self.setup_checker().check_setup_status().hooks)
    }
}
