use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use super::files::FileIdentity;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScanSummary {
    pub entries: Vec<ScanEntry>,
    pub markdown_files: usize,
    pub attachment_files: usize,
    pub other_files: usize,
    pub skipped_directories: usize,
    pub skipped_symlinks: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScanEntry {
    pub relative_path: PathBuf,
    pub kind: ScanEntryKind,
    pub size_bytes: u64,
    pub modified: Option<SystemTime>,
    pub file_identity: FileIdentity,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScanEntryKind {
    Markdown,
    Attachment,
    Other,
}

pub fn classify_file(path: &Path) -> ScanEntryKind {
    let extension = path
        .extension()
        .and_then(OsStr::to_str)
        .map(str::to_ascii_lowercase);

    match extension.as_deref() {
        Some("md" | "markdown") => ScanEntryKind::Markdown,
        Some(
            "avif" | "bmp" | "gif" | "jpeg" | "jpg" | "mov" | "mp3" | "mp4" | "pdf" | "png" | "svg"
            | "tif" | "tiff" | "wav" | "webp" | "zip",
        ) => ScanEntryKind::Attachment,
        _ => ScanEntryKind::Other,
    }
}
