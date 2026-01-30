//! Process inspection helpers for the daemon.

use sysinfo::{Pid, ProcessRefreshKind, System};

pub fn get_process_start_time(pid: u32) -> Option<u64> {
    let mut sys = System::new();
    let sys_pid = Pid::from(pid as usize);
    sys.refresh_process_specifics(sys_pid, ProcessRefreshKind::new());
    sys.process(sys_pid).map(|process| process.start_time())
}
