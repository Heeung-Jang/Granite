use std::fs;
use std::path::Path;
use std::time::Duration;

pub(crate) fn percentile_duration(values: &[Duration], percentile: usize) -> Duration {
    if values.is_empty() {
        return Duration::ZERO;
    }
    let index = ((values.len() * percentile).div_ceil(100)).saturating_sub(1);
    values[index.min(values.len() - 1)]
}

pub(crate) fn duration_micros_nonzero(duration: Duration) -> u64 {
    (duration.as_micros().min(u128::from(u64::MAX)) as u64).max(1)
}

pub(crate) fn directory_size(path: &Path) -> std::io::Result<u64> {
    let mut size = 0;
    for entry in fs::read_dir(path)? {
        let path = entry?.path();
        let metadata = fs::metadata(&path)?;
        if metadata.is_dir() {
            size += directory_size(&path)?;
        } else {
            size += metadata.len();
        }
    }
    Ok(size)
}
