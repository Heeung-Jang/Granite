pub mod corpus;
pub mod synthetic;

use serde::Serialize;
use std::cmp::Reverse;
use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct ProfileOptions {
    pub vault_root: PathBuf,
    pub largest_limit: usize,
    pub include_paths: bool,
}

#[derive(Debug, Serialize)]
pub struct VaultProfile {
    pub schema_version: u32,
    pub profiler_version: String,
    pub vault: VaultIdentity,
    pub totals: ProfileTotals,
    pub extensions: BTreeMap<String, ExtensionStats>,
    pub markdown_size_distribution: BTreeMap<String, u64>,
    pub largest_files: Vec<FileSizeRecord>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct VaultIdentity {
    pub root_name: String,
    pub root_hash: String,
}

#[derive(Debug, Default, Serialize)]
pub struct ProfileTotals {
    pub total_files: u64,
    pub markdown_files: u64,
    pub folders: u64,
    pub symlinks: u64,
    pub total_bytes: u64,
    pub markdown_bytes: u64,
    pub files_with_frontmatter: u64,
    pub wikilinks: u64,
    pub embeds: u64,
    pub markdown_links: u64,
    pub inline_tags: u64,
    pub frontmatter_tags: u64,
    pub attachment_references: u64,
}

#[derive(Debug, Default, Serialize)]
pub struct ExtensionStats {
    pub files: u64,
    pub bytes: u64,
}

#[derive(Debug, Serialize)]
pub struct FileSizeRecord {
    pub relative_path_hash: String,
    pub relative_path: Option<String>,
    pub extension: String,
    pub bytes: u64,
    pub markdown: bool,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct MarkdownAnalysis {
    pub has_frontmatter: bool,
    pub wikilinks: u64,
    pub embeds: u64,
    pub markdown_links: u64,
    pub inline_tags: u64,
    pub frontmatter_tags: u64,
    pub attachment_references: u64,
}

pub fn profile_vault(options: &ProfileOptions) -> io::Result<VaultProfile> {
    let vault_root = options.vault_root.canonicalize()?;
    let mut profile = VaultProfile {
        schema_version: 1,
        profiler_version: env!("CARGO_PKG_VERSION").to_string(),
        vault: VaultIdentity {
            root_name: vault_root
                .file_name()
                .and_then(OsStr::to_str)
                .unwrap_or("vault")
                .to_string(),
            root_hash: stable_hash(vault_root.to_string_lossy().as_bytes()),
        },
        totals: ProfileTotals::default(),
        extensions: BTreeMap::new(),
        markdown_size_distribution: BTreeMap::new(),
        largest_files: Vec::new(),
        warnings: Vec::new(),
    };

    visit_dir(&vault_root, &vault_root, options, &mut profile)?;
    profile
        .largest_files
        .sort_by_key(|file| Reverse(file.bytes));
    profile.largest_files.truncate(options.largest_limit);
    Ok(profile)
}

fn visit_dir(
    vault_root: &Path,
    dir: &Path,
    options: &ProfileOptions,
    profile: &mut VaultProfile,
) -> io::Result<()> {
    for entry_result in fs::read_dir(dir)? {
        let entry = entry_result?;
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path)?;
        let file_type = metadata.file_type();

        if file_type.is_symlink() {
            profile.totals.symlinks += 1;
            continue;
        }

        if file_type.is_dir() {
            profile.totals.folders += 1;
            visit_dir(vault_root, &path, options, profile)?;
            continue;
        }

        if !file_type.is_file() {
            continue;
        }

        profile.totals.total_files += 1;
        profile.totals.total_bytes = profile.totals.total_bytes.saturating_add(metadata.len());

        let extension = normalized_extension(&path);
        let extension_stats = profile.extensions.entry(extension.clone()).or_default();
        extension_stats.files += 1;
        extension_stats.bytes = extension_stats.bytes.saturating_add(metadata.len());

        let markdown = is_markdown_path(&path);
        if markdown {
            profile.totals.markdown_files += 1;
            profile.totals.markdown_bytes =
                profile.totals.markdown_bytes.saturating_add(metadata.len());
            *profile
                .markdown_size_distribution
                .entry(size_bucket(metadata.len()).to_string())
                .or_default() += 1;

            match fs::read(&path) {
                Ok(bytes) => {
                    let text = String::from_utf8_lossy(&bytes);
                    let analysis = analyze_markdown_content(&text);
                    merge_markdown_analysis(&mut profile.totals, analysis);
                }
                Err(err) => profile.warnings.push(format!(
                    "read_failed:{}:{}",
                    path_hash(vault_root, &path),
                    err.kind()
                )),
            }
        }

        push_largest_file(
            vault_root,
            &path,
            metadata.len(),
            extension,
            markdown,
            options,
            profile,
        );
    }

    Ok(())
}

fn push_largest_file(
    vault_root: &Path,
    path: &Path,
    bytes: u64,
    extension: String,
    markdown: bool,
    options: &ProfileOptions,
    profile: &mut VaultProfile,
) {
    let relative_path = path.strip_prefix(vault_root).unwrap_or(path);
    profile.largest_files.push(FileSizeRecord {
        relative_path_hash: stable_hash(relative_path.to_string_lossy().as_bytes()),
        relative_path: options
            .include_paths
            .then(|| relative_path.to_string_lossy().to_string()),
        extension,
        bytes,
        markdown,
    });

    if profile.largest_files.len() > options.largest_limit.saturating_mul(4).max(64) {
        profile
            .largest_files
            .sort_by_key(|file| Reverse(file.bytes));
        profile.largest_files.truncate(options.largest_limit);
    }
}

fn merge_markdown_analysis(totals: &mut ProfileTotals, analysis: MarkdownAnalysis) {
    if analysis.has_frontmatter {
        totals.files_with_frontmatter += 1;
    }
    totals.wikilinks += analysis.wikilinks;
    totals.embeds += analysis.embeds;
    totals.markdown_links += analysis.markdown_links;
    totals.inline_tags += analysis.inline_tags;
    totals.frontmatter_tags += analysis.frontmatter_tags;
    totals.attachment_references += analysis.attachment_references;
}

pub fn analyze_markdown_content(text: &str) -> MarkdownAnalysis {
    let frontmatter = frontmatter_block(text);
    let wikilinks = count_non_overlapping(text, "[[") as u64;
    let embeds = count_non_overlapping(text, "![[") as u64;
    let markdown_targets = markdown_link_targets(text);
    let markdown_links = markdown_targets.len() as u64;
    let markdown_attachment_references = markdown_targets
        .iter()
        .filter(|target| is_probably_attachment_target(target))
        .count() as u64;

    MarkdownAnalysis {
        has_frontmatter: frontmatter.is_some(),
        wikilinks,
        embeds,
        markdown_links,
        inline_tags: count_inline_tags(text),
        frontmatter_tags: frontmatter.map(count_frontmatter_tags).unwrap_or(0),
        attachment_references: embeds + markdown_attachment_references,
    }
}

pub fn is_markdown_path(path: &Path) -> bool {
    matches!(
        path.extension()
            .and_then(OsStr::to_str)
            .map(|ext| ext.to_ascii_lowercase()),
        Some(ext) if ext == "md" || ext == "markdown"
    )
}

fn normalized_extension(path: &Path) -> String {
    path.extension()
        .and_then(OsStr::to_str)
        .map(|ext| ext.to_ascii_lowercase())
        .filter(|ext| !ext.is_empty())
        .unwrap_or_else(|| "(none)".to_string())
}

fn size_bucket(bytes: u64) -> &'static str {
    match bytes {
        0 => "empty",
        1..=1_024 => "1B-1KB",
        1_025..=10_240 => "1KB-10KB",
        10_241..=102_400 => "10KB-100KB",
        102_401..=1_048_576 => "100KB-1MB",
        1_048_577..=5_242_880 => "1MB-5MB",
        _ => "5MB+",
    }
}

fn frontmatter_block(text: &str) -> Option<&str> {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let mut lines = text.lines();
    if lines.next()? != "---" {
        return None;
    }

    let mut offset = 4;
    for line in lines {
        if line == "---" || line == "..." {
            return text.get(4..offset);
        }
        offset += line.len() + 1;
    }
    None
}

fn count_frontmatter_tags(frontmatter: &str) -> u64 {
    let mut count = 0;
    let mut in_tags_list = false;

    for line in frontmatter.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("tags:") {
            in_tags_list = rest.trim().is_empty();
            count += count_tag_values(rest);
            continue;
        }

        if in_tags_list && trimmed.starts_with("- ") {
            count += count_tag_values(trimmed.trim_start_matches("- "));
            continue;
        }

        if !trimmed.is_empty() && !trimmed.starts_with('#') {
            in_tags_list = false;
        }
    }

    count
}

fn count_tag_values(value: &str) -> u64 {
    let value = value.trim();
    if value.is_empty() {
        return 0;
    }

    if value.starts_with('[') && value.ends_with(']') {
        return value
            .trim_matches(['[', ']'])
            .split(',')
            .filter(|part| !part.trim().is_empty())
            .count() as u64;
    }

    1
}

fn markdown_link_targets(text: &str) -> Vec<String> {
    let mut targets = Vec::new();
    let bytes = text.as_bytes();
    let mut index = 0;

    while index + 1 < bytes.len() {
        if bytes[index] == b']' && bytes[index + 1] == b'(' {
            let target_start = index + 2;
            if let Some(relative_end) = text[target_start..].find(')') {
                let raw_target = &text[target_start..target_start + relative_end];
                if let Some(target) = raw_target.split_whitespace().next()
                    && !target.is_empty()
                {
                    targets.push(target.to_string());
                }
                index = target_start + relative_end + 1;
                continue;
            }
        }
        index += 1;
    }

    targets
}

fn is_probably_attachment_target(target: &str) -> bool {
    let target = target.split('#').next().unwrap_or(target);
    let target = target.split('?').next().unwrap_or(target);
    let Some(extension) = Path::new(target).extension().and_then(OsStr::to_str) else {
        return false;
    };
    matches!(
        extension.to_ascii_lowercase().as_str(),
        "avif"
            | "bmp"
            | "gif"
            | "jpeg"
            | "jpg"
            | "mov"
            | "mp3"
            | "mp4"
            | "pdf"
            | "png"
            | "svg"
            | "tif"
            | "tiff"
            | "wav"
            | "webp"
            | "zip"
    )
}

fn count_inline_tags(text: &str) -> u64 {
    text.lines().map(count_inline_tags_in_line).sum()
}

fn count_inline_tags_in_line(line: &str) -> u64 {
    let trimmed_start = line.trim_start();
    if trimmed_start.starts_with('#')
        && trimmed_start
            .chars()
            .find(|ch| *ch != '#')
            .is_some_and(char::is_whitespace)
    {
        return 0;
    }

    let chars: Vec<(usize, char)> = line.char_indices().collect();
    let mut count = 0;

    for (position, (byte_index, ch)) in chars.iter().enumerate() {
        if *ch != '#' {
            continue;
        }

        let previous = position
            .checked_sub(1)
            .and_then(|index| chars.get(index))
            .map(|(_, ch)| *ch);
        let next = chars.get(position + 1).map(|(_, ch)| *ch);

        if previous.is_some_and(|ch| ch.is_alphanumeric() || ch == '_') {
            continue;
        }

        let Some(next) = next else {
            continue;
        };

        if !(next.is_alphanumeric() || next == '_' || next == '/' || next == '-') {
            continue;
        }

        let tag_tail = &line[*byte_index + ch.len_utf8()..];
        if tag_tail
            .chars()
            .take_while(|ch| ch.is_alphanumeric() || matches!(ch, '_' | '-' | '/'))
            .any(|ch| ch.is_alphabetic())
        {
            count += 1;
        }
    }

    count
}

fn count_non_overlapping(text: &str, needle: &str) -> usize {
    if needle.is_empty() {
        return 0;
    }
    text.match_indices(needle).count()
}

fn path_hash(vault_root: &Path, path: &Path) -> String {
    let relative_path = path.strip_prefix(vault_root).unwrap_or(path);
    stable_hash(relative_path.to_string_lossy().as_bytes())
}

pub fn stable_hash(bytes: &[u8]) -> String {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

pub fn is_output_inside_vault(vault_root: &Path, output_path: &Path) -> io::Result<bool> {
    let vault_root = vault_root.canonicalize()?;
    let parent = output_path
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."))
        .canonicalize()?;
    Ok(parent == vault_root || parent.starts_with(&vault_root))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::{self, File};
    use tempfile::tempdir;

    #[test]
    fn detects_markdown_extensions_case_insensitively() {
        assert!(is_markdown_path(Path::new("note.md")));
        assert!(is_markdown_path(Path::new("note.MARKDOWN")));
        assert!(!is_markdown_path(Path::new("note.txt")));
    }

    #[test]
    fn analyzes_common_markdown_features() {
        let text = r#"---
tags: [project/native, rust]
---
# Heading
Body #tag/one with [[Note]] and ![[image.png]] plus [asset](files/report.pdf).
"#;

        assert_eq!(
            analyze_markdown_content(text),
            MarkdownAnalysis {
                has_frontmatter: true,
                wikilinks: 2,
                embeds: 1,
                markdown_links: 1,
                inline_tags: 1,
                frontmatter_tags: 2,
                attachment_references: 2,
            }
        );
    }

    #[test]
    fn profile_vault_counts_files_without_following_symlinks() {
        let dir = tempdir().expect("tempdir");
        fs::create_dir(dir.path().join("folder")).expect("folder");
        fs::write(dir.path().join("folder").join("a.md"), "# A\n#tag\n[[B]]").expect("md");
        fs::write(dir.path().join("image.png"), "png").expect("png");
        File::create(dir.path().join("empty")).expect("empty");

        let profile = profile_vault(&ProfileOptions {
            vault_root: dir.path().to_path_buf(),
            largest_limit: 5,
            include_paths: false,
        })
        .expect("profile");

        assert_eq!(profile.totals.total_files, 3);
        assert_eq!(profile.totals.markdown_files, 1);
        assert_eq!(profile.totals.folders, 1);
        assert_eq!(profile.totals.wikilinks, 1);
        assert_eq!(profile.totals.inline_tags, 1);
        assert!(
            profile
                .largest_files
                .iter()
                .all(|file| file.relative_path.is_none())
        );
    }

    #[test]
    fn rejects_output_paths_inside_vault() {
        let dir = tempdir().expect("tempdir");
        let output = dir.path().join("artifact.json");
        assert!(is_output_inside_vault(dir.path(), &output).expect("path check"));
    }
}
