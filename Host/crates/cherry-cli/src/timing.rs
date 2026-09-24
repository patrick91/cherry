//! Timing of the attachment, and how much input it buffers. Tests shorten
//! them through `CHERRY_CLI_*_MS` variables and `CHERRY_CLI_INPUT_HIGH_WATER`,
//! as they do for cherry-host with `CHERRY_HOST_*_MS`.
use std::{sync::OnceLock, time::Duration};

pub struct Timing {
    /// An attached client sends Ping this often.
    pub heartbeat_interval: Duration,
    /// An attachment is dead when its transport accepts nothing and delivers
    /// nothing for this long while input is waiting.
    pub heartbeat_timeout: Duration,
    /// See `input::ESCAPE_WAIT`.
    pub escape_wait: Duration,
    /// See `attach::GRID_WAIT`.
    pub grid_wait: Duration,
    /// See `attach::DETACH_WAIT`.
    pub detach_wait: Duration,
    /// See `attach::REPORT_WAIT`.
    pub report_wait: Duration,
    /// See `transport::CLOSED_WAIT`.
    pub closed_wait: Duration,
    /// See `attach::INPUT_HIGH_WATER` (bytes).
    pub input_high_water: usize,
}

pub fn timing() -> &'static Timing {
    static TIMING: OnceLock<Timing> = OnceLock::new();
    TIMING.get_or_init(|| {
        let millis = |name: &str, default: Duration| {
            std::env::var(name)
                .ok()
                .and_then(|value| value.parse().ok())
                .map_or(default, Duration::from_millis)
        };
        Timing {
            heartbeat_interval: millis(
                "CHERRY_CLI_HEARTBEAT_INTERVAL_MS",
                cherry_protocol::HEARTBEAT_INTERVAL,
            ),
            heartbeat_timeout: millis(
                "CHERRY_CLI_HEARTBEAT_TIMEOUT_MS",
                cherry_protocol::HEARTBEAT_TIMEOUT,
            ),
            escape_wait: millis("CHERRY_CLI_ESCAPE_WAIT_MS", crate::input::ESCAPE_WAIT),
            grid_wait: millis("CHERRY_CLI_GRID_WAIT_MS", crate::attach::GRID_WAIT),
            detach_wait: millis("CHERRY_CLI_DETACH_WAIT_MS", crate::attach::DETACH_WAIT),
            report_wait: millis("CHERRY_CLI_REPORT_WAIT_MS", crate::attach::REPORT_WAIT),
            closed_wait: millis("CHERRY_CLI_CLOSED_WAIT_MS", crate::transport::CLOSED_WAIT),
            input_high_water: std::env::var("CHERRY_CLI_INPUT_HIGH_WATER")
                .ok()
                .and_then(|value| value.parse().ok())
                .unwrap_or(crate::attach::INPUT_HIGH_WATER),
        }
    })
}
