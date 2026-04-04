use super::env::managed_command_hook_command;
use crate::runtime::state::snapshot::test_support::env_lock as shared_env_lock;
use crate::runtime::storage::StorageConfig;
use fs_err as fs;
use tempfile::TempDir;

pub(super) struct EnvVarGuard {
    key: &'static str,
    original: Option<String>,
}

impl EnvVarGuard {
    pub(super) fn set(key: &'static str, value: &std::path::Path) -> Self {
        let original = std::env::var(key).ok();
        std::env::set_var(key, value);
        Self { key, original }
    }
}

impl Drop for EnvVarGuard {
    fn drop(&mut self) {
        if let Some(value) = &self.original {
            std::env::set_var(self.key, value);
        } else {
            std::env::remove_var(self.key);
        }
    }
}

pub(super) fn env_lock() -> std::sync::MutexGuard<'static, ()> {
    shared_env_lock()
}

#[cfg(unix)]
pub(super) fn write_executable_script(path: &std::path::Path, script: &str) {
    use std::os::unix::fs::PermissionsExt;

    fs::write(path, script).expect("write script");
    let mut perms = fs::metadata(path).expect("script metadata").permissions();
    perms.set_mode(0o755);
    fs::set_permissions(path, perms).expect("set executable permission");
}

#[cfg(unix)]
pub(super) fn install_working_hook_binary(home: &std::path::Path) {
    let bin_dir = home.join(".local/bin");
    fs::create_dir_all(&bin_dir).expect("create bin dir");
    write_executable_script(
        &bin_dir.join("hud-hook"),
        "#!/bin/sh\n\
         if [ \"$1\" = \"--help\" ]; then\n\
           echo \"Commands: serve cwd\"\n\
           exit 0\n\
         fi\n\
         exit 0\n",
    );
}

pub(super) fn setup_test_env() -> (TempDir, StorageConfig) {
    let temp = TempDir::new().unwrap();
    let capacitor_root = temp.path().join(".capacitor");
    let claude_root = temp.path().join(".claude");
    fs::create_dir_all(&capacitor_root).unwrap();
    fs::create_dir_all(&claude_root).unwrap();
    let storage = StorageConfig::with_roots(capacitor_root, claude_root);
    (temp, storage)
}

pub(super) fn retired_handle_command() -> String {
    ["hud-hook", "handle"].join(" ")
}

pub(super) fn retired_prefixed_handle_command() -> String {
    format!(
        "CAPACITOR_CORE_ENABLED=1 $HOME/.local/bin/{}",
        retired_handle_command()
    )
}

pub(super) fn retired_state_tracker_command() -> String {
    ["hud", "state", "tracker"].join("-")
}

pub(super) fn marker_prefixed_managed_command() -> String {
    format!(
        "{} {}",
        ["CAPACITOR", "HOOK", "MARKER=1"].join("_"),
        managed_command_hook_command()
    )
}
