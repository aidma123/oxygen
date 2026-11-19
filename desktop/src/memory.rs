//! Measures the browser's real memory footprint: this process plus every
//! process it spawned (on Windows: the msedgewebview2.exe browser, renderer,
//! GPU and utility processes).

use std::collections::HashMap;
use sysinfo::{Pid, ProcessRefreshKind, ProcessesToUpdate, System};

pub struct Meter {
    sys: Option<System>,
    me: Option<Pid>,
}

impl Meter {
    pub fn new() -> Self {
        Self {
            sys: System::new().ok(),
            me: sysinfo::get_current_pid().ok(),
        }
    }

    /// Total resident memory of the process tree, in MB.
    pub fn total_mb(&mut self) -> u64 {
        let (Some(me), Some(sys)) = (self.me, self.sys.as_mut()) else { return 0 };
        sys.refresh_processes_specifics(
            ProcessesToUpdate::All,
            true,
            ProcessRefreshKind::nothing().with_memory(),
        );
        let procs = sys.processes();
        let mut children: HashMap<Pid, Vec<Pid>> = HashMap::new();
        for (pid, p) in procs {
            // On Linux, threads show up as processes that share their parent's
            // memory; counting them would multiply the total.
            if p.thread_kind().is_some() {
                continue;
            }
            if let Some(parent) = p.parent() {
                children.entry(parent).or_default().push(*pid);
            }
        }
        let mut total = 0u64;
        let mut stack = vec![me];
        let mut seen = std::collections::HashSet::new();
        while let Some(pid) = stack.pop() {
            if !seen.insert(pid) {
                continue;
            }
            if let Some(p) = procs.get(&pid) {
                total += p.memory();
            }
            if let Some(kids) = children.get(&pid) {
                stack.extend(kids.iter().copied());
            }
        }
        total / (1024 * 1024)
    }
}
