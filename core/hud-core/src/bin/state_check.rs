use hud_core::state::{get_lock_info, is_session_running, resolve_state, StateStore};

fn main() {
    let home = dirs::home_dir().expect("No home directory");
    let lock_dir = home.join(".claude/sessions");
    let state_file = home.join(".claude/hud-session-states-v2.json");

    println!("═══════════════════════════════════════════════════════════");
    println!("  Claude HUD State Check - Validation Harness");
    println!("═══════════════════════════════════════════════════════════");
    println!();

    println!("Lock directory: {}", lock_dir.display());
    println!("State file: {}", state_file.display());
    println!();

    println!("── Active Locks ──────────────────────────────────────────");
    if lock_dir.exists() {
        let mut found_locks = false;
        for entry in std::fs::read_dir(&lock_dir).unwrap() {
            let entry = entry.unwrap();
            let path = entry.path();
            if path.is_dir() && path.extension().map(|e| e == "lock").unwrap_or(false) {
                found_locks = true;
                let pid_file = path.join("pid");
                let meta_file = path.join("meta.json");

                if let Ok(pid_str) = std::fs::read_to_string(&pid_file) {
                    let pid: u32 = pid_str.trim().parse().unwrap_or(0);
                    let alive = unsafe { libc::kill(pid as i32, 0) == 0 };

                    if let Ok(meta_content) = std::fs::read_to_string(&meta_file) {
                        if let Ok(meta) = serde_json::from_str::<serde_json::Value>(&meta_content) {
                            let project_path = meta.get("path").and_then(|v| v.as_str()).unwrap_or("?");
                            let status = if alive { "✓ ALIVE" } else { "✗ DEAD" };
                            println!("  {} PID {} → {}", status, pid, project_path);
                        }
                    }
                }
            }
        }
        if !found_locks {
            println!("  (no lock files found)");
        }
    } else {
        println!("  (lock directory doesn't exist)");
    }
    println!();

    let args: Vec<String> = std::env::args().collect();
    let test_paths: Vec<&str> = if args.len() > 1 {
        args[1..].iter().map(|s| s.as_str()).collect()
    } else {
        vec![
            "/Users/petepetrash/Code/claude-hud",
            "/Users/petepetrash/Code",
            "/Users/petepetrash/Code/claude-hud/apps/swift",
        ]
    };

    println!("── Lock Detection Tests ──────────────────────────────────");
    for path in &test_paths {
        let running = is_session_running(&lock_dir, path);
        let status = if running { "🟢 RUNNING" } else { "⚫ NOT RUNNING" };
        println!("  {} {}", status, path);

        if let Some(info) = get_lock_info(&lock_dir, path) {
            println!("       └─ inherited from: {} (PID {})", info.path, info.pid);
        }
    }
    println!();

    println!("── State Resolution Tests ────────────────────────────────");
    let store = StateStore::load(&state_file).unwrap_or_else(|_| StateStore::new(&state_file));

    for path in &test_paths {
        let state = resolve_state(&lock_dir, &store, path);
        let status = match state {
            Some(s) => format!("{:?}", s),
            None => "None (not running)".to_string(),
        };
        println!("  {} → {}", path, status);
    }
    println!();

    println!("── All Stored Sessions ───────────────────────────────────");
    let sessions: Vec<_> = store.all_sessions().collect();
    if sessions.is_empty() {
        println!("  (no sessions in state file)");
    } else {
        for record in sessions {
            println!(
                "  {} │ {:?} │ {}",
                &record.session_id[..8.min(record.session_id.len())],
                record.state,
                record.cwd
            );
        }
    }
    println!();

    println!("═══════════════════════════════════════════════════════════");
    println!("  Validation complete");
    println!("═══════════════════════════════════════════════════════════");
}
