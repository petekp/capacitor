use super::{InstallResult, SetupChecker};
use crate::runtime::error::HudFfiError;
use fs_err as fs;
use std::path::{Path, PathBuf};

pub(super) struct ResolvedSymlinkTarget {
    pub(super) target_path: PathBuf,
    pub(super) canonical_target: Option<PathBuf>,
}

impl SetupChecker {
    pub(super) fn check_storage(&self) -> bool {
        let root = self.storage.root();
        if !root.exists() && fs::create_dir_all(root).is_err() {
            return false;
        }
        root.exists() && root.is_dir()
    }

    pub(super) fn get_hook_binary_path(&self) -> PathBuf {
        dirs::home_dir()
            .map(|h| h.join(".local/bin/hud-hook"))
            .unwrap_or_else(|| PathBuf::from("/usr/local/bin/hud-hook"))
    }

    pub(crate) fn install_binary_from_path(
        &self,
        source_path: &str,
    ) -> Result<InstallResult, HudFfiError> {
        use std::os::unix::fs::symlink;

        let source = std::path::Path::new(source_path);
        if !source.exists() {
            return Ok(InstallResult {
                success: false,
                message: format!("Source binary not found at {}", source_path),
                script_path: None,
            });
        }

        let source_abs = source.canonicalize().map_err(|e| HudFfiError::General {
            message: format!("Failed to resolve source path: {}", e),
        })?;

        let dest_dir = dirs::home_dir()
            .ok_or_else(|| HudFfiError::General {
                message: "Could not determine home directory".to_string(),
            })?
            .join(".local/bin");

        let dest_path = dest_dir.join("hud-hook");

        if let Ok(Some(current_target)) = resolve_symlink_target(&dest_path) {
            if current_target
                .canonical_target
                .as_ref()
                .is_some_and(|target| target == &source_abs)
            {
                return Ok(InstallResult {
                    success: true,
                    message: "Hook binary symlink already correct".to_string(),
                    script_path: Some(dest_path.to_string_lossy().to_string()),
                });
            }
        }

        fs::create_dir_all(&dest_dir).map_err(|e| HudFfiError::General {
            message: format!("Failed to create ~/.local/bin: {}", e),
        })?;

        if dest_path.exists() || dest_path.is_symlink() {
            fs::remove_file(&dest_path).map_err(|e| HudFfiError::General {
                message: format!("Failed to remove existing binary/symlink: {}", e),
            })?;
        }

        symlink(&source_abs, &dest_path).map_err(|e| HudFfiError::General {
            message: format!("Failed to create symlink: {}", e),
        })?;

        Ok(InstallResult {
            success: true,
            message: format!(
                "Hook binary symlinked: {} -> {}",
                dest_path.display(),
                source_abs.display()
            ),
            script_path: Some(dest_path.to_string_lossy().to_string()),
        })
    }
}

pub(super) fn resolve_symlink_target(path: &Path) -> Result<Option<ResolvedSymlinkTarget>, String> {
    if !path.is_symlink() {
        return Ok(None);
    }

    let target = fs::read_link(path).map_err(|e| format!("Cannot read symlink: {}", e))?;
    let target_path = if target.is_absolute() {
        target
    } else {
        path.parent()
            .map(|parent| parent.join(&target))
            .unwrap_or(target)
    };

    let canonical_target = fs::canonicalize(&target_path).ok();
    Ok(Some(ResolvedSymlinkTarget {
        target_path,
        canonical_target,
    }))
}

#[cfg(test)]
mod tests {
    use super::super::test_support::{
        env_lock, setup_test_env, write_executable_script, EnvVarGuard,
    };
    use super::super::SetupChecker;
    use fs_err as fs;

    #[test]
    fn test_install_binary_source_not_found() {
        let (_temp, storage) = setup_test_env();
        let checker = SetupChecker::new(storage);

        let result = checker
            .install_binary_from_path("/nonexistent/path/to/binary")
            .unwrap();

        assert!(!result.success);
        assert!(result.message.contains("not found"));
    }

    #[cfg(unix)]
    #[test]
    fn test_install_binary_from_path_keeps_relative_symlink_to_same_target() {
        use std::os::unix::fs::symlink;

        let _guard = env_lock();
        let (temp, storage) = setup_test_env();
        let home = temp.path();
        let _home_guard = EnvVarGuard::set("HOME", home);

        let build_dir = home.join("build");
        fs::create_dir_all(&build_dir).expect("create build dir");
        let source_binary = build_dir.join("hud-hook");
        write_executable_script(
            &source_binary,
            "#!/bin/sh\n\
             if [ \"$1\" = \"--help\" ]; then\n\
               echo \"Commands: serve cwd\"\n\
               exit 0\n\
             fi\n\
             exit 0\n",
        );

        let bin_dir = home.join(".local/bin");
        fs::create_dir_all(&bin_dir).expect("create bin dir");
        let symlink_path = bin_dir.join("hud-hook");
        symlink("../../build/hud-hook", &symlink_path).expect("create relative symlink");

        let checker = SetupChecker::new(storage);
        let result = checker
            .install_binary_from_path(source_binary.to_string_lossy().as_ref())
            .expect("install binary from path");
        assert!(result.success);
        assert!(
            result.message.contains("already correct"),
            "relative symlink to the same binary should be preserved, got: {}",
            result.message
        );
    }
}
