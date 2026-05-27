use std::fs;
use std::path::Path;
use std::time::{Duration, Instant};

pub(crate) fn read_markdown_body(path: &Path) -> std::io::Result<(String, u64)> {
    let start = Instant::now();
    let body = fs::read_to_string(path)?;
    Ok((body, duration_micros_nonzero(start.elapsed())))
}

fn duration_micros(duration: Duration) -> u64 {
    duration.as_micros().min(u128::from(u64::MAX)) as u64
}

fn duration_micros_nonzero(duration: Duration) -> u64 {
    duration_micros(duration).max(1)
}
