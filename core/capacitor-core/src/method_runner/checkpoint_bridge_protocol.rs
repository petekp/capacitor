use std::ffi::OsString;
use std::io::Write;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

pub const CHECKPOINT_BRIDGE_PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CheckpointBridgePending {
    pub version: u32,
    pub project_path: String,
    pub run_id: String,
    pub checkpoint_id: String,
    pub phase_id: String,
    pub gate_type: String,
    pub manifest_path: String,
    pub created_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CheckpointBridgeDecision {
    pub version: u32,
    pub run_id: String,
    pub checkpoint_id: String,
    pub action: String,
    #[serde(default)]
    pub note: Option<String>,
    pub decided_at: String,
}

pub fn pending_path(home_dir: &Path, run_id: &str, checkpoint_id: &str) -> PathBuf {
    bridge_run_dir(home_dir, run_id).join(format!("{checkpoint_id}.pending.json"))
}

pub fn decision_path(home_dir: &Path, run_id: &str, checkpoint_id: &str) -> PathBuf {
    bridge_run_dir(home_dir, run_id).join(format!("{checkpoint_id}.json"))
}

pub fn write_json_atomic<T>(path: &Path, value: &T) -> Result<(), String>
where
    T: Serialize,
{
    if let Some(parent) = path.parent() {
        fs_err::create_dir_all(parent).map_err(|error| {
            format!(
                "Failed to create checkpoint bridge directory {:?}: {error}",
                parent
            )
        })?;
    }

    let payload = serde_json::to_vec_pretty(value)
        .map_err(|error| format!("Failed to serialize checkpoint bridge payload: {error}"))?;
    let tmp_path = temporary_path(path);

    let mut file = fs_err::File::create(&tmp_path).map_err(|error| {
        format!(
            "Failed to create checkpoint bridge temp file {:?}: {error}",
            tmp_path
        )
    })?;
    file.write_all(&payload).map_err(|error| {
        format!(
            "Failed to write checkpoint bridge temp file {:?}: {error}",
            tmp_path
        )
    })?;
    file.sync_all().map_err(|error| {
        format!(
            "Failed to sync checkpoint bridge temp file {:?}: {error}",
            tmp_path
        )
    })?;
    drop(file);

    fs_err::rename(&tmp_path, path).map_err(|error| {
        format!(
            "Failed to move checkpoint bridge payload {:?} into place {:?}: {error}",
            tmp_path, path
        )
    })
}

fn bridge_run_dir(home_dir: &Path, run_id: &str) -> PathBuf {
    home_dir
        .join(".capacitor")
        .join("runtime")
        .join("checkpoint-bridge")
        .join(run_id)
}

fn temporary_path(path: &Path) -> PathBuf {
    let file_name = path
        .file_name()
        .map(|name| name.to_os_string())
        .unwrap_or_else(|| OsString::from("checkpoint-bridge"));
    let mut tmp_name = file_name;
    tmp_name.push(".tmp");
    path.with_file_name(tmp_name)
}
