use crate::stable_hash;
use serde::Serialize;
use std::ffi::OsStr;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

const DEFAULT_TARGET_MARKDOWN_COUNT: u64 = 64_306;
const PNG_1X1_TRANSPARENT: &[u8] = &[
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0,
    0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 255, 255, 63, 0, 5,
    254, 2, 254, 167, 53, 129, 132, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyntheticProfile {
    Small,
    Double,
    Quintuple,
}

impl SyntheticProfile {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "small" => Some(Self::Small),
            "2x" => Some(Self::Double),
            "5x" => Some(Self::Quintuple),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Small => "small",
            Self::Double => "2x",
            Self::Quintuple => "5x",
        }
    }

    fn note_count(self, target_markdown_count: u64) -> u64 {
        match self {
            Self::Small => target_markdown_count.clamp(50, 500).min(200),
            Self::Double => target_markdown_count.saturating_mul(2),
            Self::Quintuple => target_markdown_count.saturating_mul(5),
        }
    }
}

#[derive(Debug, Clone)]
pub struct SyntheticVaultOptions {
    pub output_root: PathBuf,
    pub profile: SyntheticProfile,
    pub seed: u64,
    pub target_markdown_count: u64,
}

impl Default for SyntheticVaultOptions {
    fn default() -> Self {
        Self {
            output_root: PathBuf::from("fixtures/generated/synthetic-small"),
            profile: SyntheticProfile::Small,
            seed: 20260519,
            target_markdown_count: DEFAULT_TARGET_MARKDOWN_COUNT,
        }
    }
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct SyntheticVaultManifest {
    pub schema_version: u32,
    pub generator_version: String,
    pub profile: String,
    pub seed: u64,
    pub target_markdown_count: u64,
    pub note_count: u64,
    pub attachment_count: u64,
    pub duplicate_basename_notes: u64,
    pub long_file_count: u64,
    pub korean_cjk_note_count: u64,
    pub output_root_name: String,
    pub output_root_hash: String,
    pub patterns: Vec<String>,
}

pub fn generate_synthetic_vault(
    options: &SyntheticVaultOptions,
) -> io::Result<SyntheticVaultManifest> {
    ensure_empty_or_missing(&options.output_root)?;
    fs::create_dir_all(options.output_root.join(".obsidian"))?;
    fs::create_dir_all(options.output_root.join("attachments"))?;
    fs::write(
        options.output_root.join(".obsidian").join("app.json"),
        "{}\n",
    )?;

    let note_count = options.profile.note_count(options.target_markdown_count);
    let attachment_count = note_count.div_ceil(20).max(1);
    write_attachments(&options.output_root, attachment_count)?;

    let mut duplicate_basename_notes = 0;
    let mut long_file_count = 0;
    let mut korean_cjk_note_count = 0;

    for index in 0..note_count {
        let note = synthetic_note(index, note_count, attachment_count, options.seed);
        if note.duplicate_basename {
            duplicate_basename_notes += 1;
        }
        if note.long_file {
            long_file_count += 1;
        }
        if note.korean_cjk {
            korean_cjk_note_count += 1;
        }

        let path = options.output_root.join(note.relative_path);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(path, note.content)?;
    }

    let manifest = SyntheticVaultManifest {
        schema_version: 1,
        generator_version: env!("CARGO_PKG_VERSION").to_string(),
        profile: options.profile.as_str().to_string(),
        seed: options.seed,
        target_markdown_count: options.target_markdown_count,
        note_count,
        attachment_count,
        duplicate_basename_notes,
        long_file_count,
        korean_cjk_note_count,
        output_root_name: options
            .output_root
            .file_name()
            .and_then(OsStr::to_str)
            .unwrap_or("synthetic-vault")
            .to_string(),
        output_root_hash: stable_hash(
            format!(
                "{}:{}:{}",
                options.profile.as_str(),
                options.seed,
                note_count
            )
            .as_bytes(),
        ),
        patterns: vec![
            "wikilinks".to_string(),
            "markdown_links".to_string(),
            "aliases".to_string(),
            "headings".to_string(),
            "duplicate_basenames".to_string(),
            "missing_links".to_string(),
            "embeds".to_string(),
            "inline_tags".to_string(),
            "frontmatter_properties".to_string(),
            "attachments".to_string(),
            "long_files".to_string(),
            "korean_cjk_text".to_string(),
        ],
    };

    let manifest_json = serde_json::to_string_pretty(&manifest)?;
    fs::write(
        options.output_root.join("synthetic-vault-manifest.json"),
        format!("{manifest_json}\n"),
    )?;
    Ok(manifest)
}

struct SyntheticNote {
    relative_path: PathBuf,
    content: String,
    duplicate_basename: bool,
    long_file: bool,
    korean_cjk: bool,
}

fn synthetic_note(index: u64, note_count: u64, attachment_count: u64, seed: u64) -> SyntheticNote {
    let duplicate_basename = index.is_multiple_of(100);
    let long_file = index.is_multiple_of(250);
    let korean_cjk = index.is_multiple_of(7);
    let folder = format!("notes/{:03}", index % 128);
    let file_name = if duplicate_basename {
        "Duplicate.md".to_string()
    } else if korean_cjk {
        format!("한국어 노트 {index:06}.md")
    } else if index.is_multiple_of(11) {
        format!("Project {index:06} Planning.md")
    } else {
        format!("Synthetic Note {index:06}.md")
    };
    let relative_path = PathBuf::from(folder).join(file_name);

    let title = note_title(index);
    let next = note_title((index + 1) % note_count);
    let previous = note_title((index + note_count - 1) % note_count);
    let random_target = note_title(deterministic_number(seed, index, note_count));
    let attachment_index = index % attachment_count;
    let korean_line = if korean_cjk {
        "한국어 문장과 漢字 토큰을 포함한 검색 테스트 본문입니다."
    } else {
        "This synthetic note contains deterministic English benchmark text."
    };

    let mut content = format!(
        "---\n\
title: {title}\n\
aliases: [{title} Alias, Shared Alias {alias_group}]\n\
tags: [synthetic/group-{group}, synthetic/seed-{seed_mod}, lang/{lang}]\n\
status: {status}\n\
rank: {index}\n\
created: 2026-05-19\n\
---\n\
# {title}\n\n\
{korean_line}\n\n\
Links: [[{next}]], [[{previous}]], [[{random_target}#Heading]], [[Missing Synthetic {missing}|Missing Alias]].\n\n\
Markdown link: [Synthetic asset](../attachments/asset-{attachment_index:06}.png)\n\n\
Embed: ![[asset-{attachment_index:06}.png]]\n\n\
#synthetic/tag-{tag} #workflow/benchmark\n\n\
## Heading\n\n\
Deterministic phrase {phrase} appears for body-search stress cases.\n",
        alias_group = index % 25,
        group = index % 40,
        seed_mod = seed % 97,
        lang = if korean_cjk { "ko" } else { "en" },
        status = if index.is_multiple_of(3) {
            "active"
        } else {
            "draft"
        },
        missing = index % 1000,
        tag = index % 75,
        phrase = deterministic_number(seed, index, 10_000),
    );

    if long_file {
        for paragraph in 0..150 {
            content.push_str(&format!(
                "\nLong paragraph {paragraph:03}: repeated deterministic content for note {index:06}, link [[{}]], tag #long/file, and Korean token 데이터.\n",
                note_title((index + paragraph + 17) % note_count)
            ));
        }
    }

    SyntheticNote {
        relative_path,
        content,
        duplicate_basename,
        long_file,
        korean_cjk,
    }
}

fn write_attachments(output_root: &Path, attachment_count: u64) -> io::Result<()> {
    for index in 0..attachment_count {
        fs::write(
            output_root
                .join("attachments")
                .join(format!("asset-{index:06}.png")),
            PNG_1X1_TRANSPARENT,
        )?;
    }
    Ok(())
}

fn ensure_empty_or_missing(path: &Path) -> io::Result<()> {
    if path.exists() && fs::read_dir(path)?.next().is_some() {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            format!("output directory is not empty: {}", path.display()),
        ));
    }
    Ok(())
}

fn note_title(index: u64) -> String {
    format!("Synthetic Note {index:06}")
}

fn deterministic_number(seed: u64, index: u64, modulo: u64) -> u64 {
    let hash = stable_hash(format!("{seed}:{index}").as_bytes());
    u64::from_str_radix(&hash[..16], 16).unwrap_or(0) % modulo.max(1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use tempfile::tempdir;
    use vault_engine::benchmarks::{
        VaultBackendBenchmarkOptions, run_shared_backend_benchmark_from_vault,
    };

    const ALLOWED_REGRESSION: f64 = 0.10;
    const QUERY_P95_BASELINE_MICROS: u64 = 4_500_000;
    const MIN_DOCS_PER_SECOND_BASELINE: f64 = 1.0;
    const PEAK_RSS_BASELINE_BYTES: u64 = 6 * 1024 * 1024 * 1024;

    #[test]
    fn generates_deterministic_vault_from_seed() {
        let first = tempdir().expect("first tempdir");
        let second = tempdir().expect("second tempdir");
        let first_output = first.path().join("synthetic");
        let second_output = second.path().join("synthetic");

        let first_manifest = generate_synthetic_vault(&SyntheticVaultOptions {
            output_root: first_output.clone(),
            profile: SyntheticProfile::Small,
            seed: 42,
            target_markdown_count: 60,
        })
        .expect("first vault");
        let second_manifest = generate_synthetic_vault(&SyntheticVaultOptions {
            output_root: second_output.clone(),
            profile: SyntheticProfile::Small,
            seed: 42,
            target_markdown_count: 60,
        })
        .expect("second vault");

        assert_eq!(first_manifest.note_count, 60);
        assert_eq!(
            snapshot_without_root(&first_output),
            snapshot_without_root(&second_output)
        );
        assert_eq!(first_manifest.profile, second_manifest.profile);
        assert_eq!(first_manifest.seed, second_manifest.seed);
    }

    #[test]
    fn generated_vault_contains_required_stress_patterns() {
        let dir = tempdir().expect("tempdir");
        let output = dir.path().join("synthetic");
        let manifest = generate_synthetic_vault(&SyntheticVaultOptions {
            output_root: output.clone(),
            profile: SyntheticProfile::Small,
            seed: 7,
            target_markdown_count: 120,
        })
        .expect("vault");

        assert!(manifest.attachment_count > 0);
        assert!(manifest.duplicate_basename_notes > 1);
        assert!(manifest.long_file_count > 0);
        assert!(manifest.korean_cjk_note_count > 0);

        let combined = combined_text(&output);
        assert!(combined.contains("[["));
        assert!(combined.contains("![["));
        assert!(combined.contains("tags:"));
        assert!(combined.contains("한국어"));
        assert!(!combined.contains("Codex Vault"));
    }

    #[test]
    fn refuses_to_write_into_non_empty_directory() {
        let dir = tempdir().expect("tempdir");
        fs::write(dir.path().join("existing.txt"), "do not overwrite").expect("write");

        let err = generate_synthetic_vault(&SyntheticVaultOptions {
            output_root: dir.path().to_path_buf(),
            profile: SyntheticProfile::Small,
            seed: 1,
            target_markdown_count: 50,
        })
        .expect_err("non-empty output must fail");

        assert_eq!(err.kind(), io::ErrorKind::AlreadyExists);
    }

    #[test]
    fn profile_scales_match_target_markdown_count() {
        assert_eq!(SyntheticProfile::Double.note_count(64_306), 128_612);
        assert_eq!(SyntheticProfile::Quintuple.note_count(64_306), 321_530);
        assert_eq!(SyntheticProfile::Small.note_count(64_306), 200);
    }

    #[test]
    fn synthetic_vault_backend_benchmark_meets_smoke_budgets() {
        let dir = tempdir().expect("tempdir");
        let vault = dir.path().join("synthetic");
        let manifest = generate_synthetic_vault(&SyntheticVaultOptions {
            output_root: vault.clone(),
            profile: SyntheticProfile::Small,
            seed: 20260520,
            target_markdown_count: 50,
        })
        .expect("synthetic vault");
        fs::write(
            vault.join("LongSynthetic.md"),
            format!(
                "# Long Synthetic\n\n{}",
                "long deterministic benchmark phrase\n".repeat(4096)
            ),
        )
        .expect("long synthetic note");

        let artifact = run_shared_backend_benchmark_from_vault(&VaultBackendBenchmarkOptions {
            corpus_id: "synthetic-performance-smoke".to_string(),
            vault_root: vault,
            queries: vec![
                "Synthetic Note".to_string(),
                "deterministic phrase".to_string(),
                "long deterministic benchmark phrase".to_string(),
                "한국어".to_string(),
                "workflow/benchmark".to_string(),
            ],
            result_limit: 10,
            work_dir: dir.path().join("indexes"),
        })
        .expect("benchmark");

        assert_eq!(artifact.document_count, manifest.note_count as usize + 1);
        assert_eq!(artifact.query_count, 5);
        assert_eq!(artifact.backends.len(), 2);

        for backend in &artifact.backends {
            assert!(
                backend.stages.read_parse.peak_in_flight_items > 0,
                "{} pipeline in-flight count",
                backend.backend
            );
            assert!(
                backend.query_p95_micros <= upper_regression_limit(QUERY_P95_BASELINE_MICROS),
                "{} query p95 exceeded smoke budget: {}us",
                backend.backend,
                backend.query_p95_micros
            );
            assert!(
                backend.docs_per_second >= lower_regression_limit(MIN_DOCS_PER_SECOND_BASELINE),
                "{} indexing throughput regressed: {:.2} docs/s",
                backend.backend,
                backend.docs_per_second
            );
            assert!(
                backend.index_size_bytes > 0,
                "{} index size",
                backend.backend
            );

            if let Some(peak_rss_bytes) = backend.peak_rss_bytes {
                assert!(
                    peak_rss_bytes <= upper_regression_limit(PEAK_RSS_BASELINE_BYTES),
                    "{} peak RSS exceeded smoke budget: {} bytes",
                    backend.backend,
                    peak_rss_bytes
                );
            }
        }
    }

    fn upper_regression_limit(baseline: u64) -> u64 {
        ((baseline as f64) * (1.0 + ALLOWED_REGRESSION)) as u64
    }

    fn lower_regression_limit(baseline: f64) -> f64 {
        baseline * (1.0 - ALLOWED_REGRESSION)
    }

    fn snapshot_without_root(root: &Path) -> BTreeMap<String, String> {
        let mut snapshot = BTreeMap::new();
        collect_snapshot(root, root, &mut snapshot);
        snapshot
    }

    fn combined_text(root: &Path) -> String {
        let mut text = String::new();
        collect_text(root, &mut text);
        text
    }

    fn collect_text(dir: &Path, text: &mut String) {
        for entry in fs::read_dir(dir).expect("read_dir") {
            let path = entry.expect("entry").path();
            if path.is_dir() {
                collect_text(&path, text);
            } else if path.extension().and_then(OsStr::to_str) == Some("md") {
                text.push_str(&fs::read_to_string(path).expect("read markdown"));
            }
        }
    }

    fn collect_snapshot(root: &Path, dir: &Path, snapshot: &mut BTreeMap<String, String>) {
        for entry in fs::read_dir(dir).expect("read_dir") {
            let path = entry.expect("entry").path();
            if path.is_dir() {
                collect_snapshot(root, &path, snapshot);
            } else {
                let relative = path
                    .strip_prefix(root)
                    .expect("relative")
                    .to_string_lossy()
                    .to_string();
                let bytes = fs::read(&path).expect("read");
                snapshot.insert(relative, stable_hash(&bytes));
            }
        }
    }
}
