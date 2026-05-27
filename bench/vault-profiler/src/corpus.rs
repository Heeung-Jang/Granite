use crate::{
    VaultIdentity, is_markdown_path, public_artifact_salt, redacted_vault_identity,
    salted_private_hash, stable_hash,
};
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsStr;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

const QUERY_CLASSES: [&str; 5] = ["file_name", "body", "backlink", "tag", "property"];
const REQUIRED_COVERAGE: [&str; 8] = [
    "english",
    "korean_cjk",
    "short",
    "phrase",
    "space",
    "duplicate_basename",
    "many_result",
    "zero_result",
];

#[derive(Debug, Clone)]
pub struct QueryCorpusOptions {
    pub vault_root: PathBuf,
    pub samples_per_class: usize,
    pub seed: u64,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct QueryCorpus {
    pub schema_version: u32,
    pub generator_version: String,
    pub vault: VaultIdentity,
    pub samples_per_class: usize,
    pub seed: u64,
    pub privacy: PrivacyPolicy,
    pub totals: BTreeMap<String, usize>,
    pub coverage: BTreeMap<String, Vec<String>>,
    pub samples: Vec<QuerySample>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct PrivacyPolicy {
    pub raw_queries_committed: bool,
    pub raw_note_snippets_committed: bool,
    pub path_values_committed: bool,
    pub query_material: String,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct QuerySample {
    pub id: String,
    pub query_class: String,
    pub query_hash: String,
    pub redacted_display: String,
    pub coverage: Vec<String>,
    pub expected_result_shape: String,
    pub source_count_hint: u64,
    pub source_hashes: Vec<String>,
}

#[derive(Debug, PartialEq, Eq)]
pub struct QueryCorpusBundle {
    pub corpus: QueryCorpus,
    pub private_query_lines: Vec<String>,
}

#[derive(Debug, Clone)]
struct Candidate {
    query_class: String,
    raw_query: String,
    source_count: u64,
    source_hashes: Vec<String>,
    coverage: BTreeSet<String>,
    file_stem_candidate: bool,
}

impl Candidate {
    fn new(query_class: &str, raw_query: &str) -> Self {
        Self {
            query_class: query_class.to_string(),
            raw_query: raw_query.to_string(),
            source_count: 0,
            source_hashes: Vec::new(),
            coverage: BTreeSet::new(),
            file_stem_candidate: false,
        }
    }
}

pub fn generate_query_corpus(options: &QueryCorpusOptions) -> io::Result<QueryCorpus> {
    Ok(generate_query_corpus_bundle(options)?.corpus)
}

pub fn generate_query_corpus_bundle(options: &QueryCorpusOptions) -> io::Result<QueryCorpusBundle> {
    let vault_root = options.vault_root.canonicalize()?;
    let artifact_salt = public_artifact_salt();
    let collector = collect_candidates(
        &vault_root,
        options.seed,
        options.samples_per_class,
        &artifact_salt,
    )?;

    Ok(QueryCorpusBundle {
        corpus: build_query_corpus(options, &collector, &artifact_salt),
        private_query_lines: private_query_lines_from_collector(
            &collector,
            options.samples_per_class,
        ),
    })
}

pub fn generate_private_query_lines(options: &QueryCorpusOptions) -> io::Result<Vec<String>> {
    Ok(generate_query_corpus_bundle(options)?.private_query_lines)
}

fn build_query_corpus(
    options: &QueryCorpusOptions,
    collector: &CorpusCollector,
    artifact_salt: &str,
) -> QueryCorpus {
    let mut samples = Vec::new();
    let mut totals = BTreeMap::new();
    let mut coverage = BTreeMap::new();

    for query_class in QUERY_CLASSES {
        let selected = collector.select_samples(query_class, options.samples_per_class);
        totals.insert(query_class.to_string(), selected.len());
        coverage.insert(query_class.to_string(), coverage_for(&selected));
        samples.extend(
            selected.into_iter().enumerate().map(|(index, candidate)| {
                sample_from_candidate(index + 1, candidate, artifact_salt)
            }),
        );
    }

    QueryCorpus {
        schema_version: 1,
        generator_version: env!("CARGO_PKG_VERSION").to_string(),
        vault: redacted_vault_identity(),
        samples_per_class: options.samples_per_class,
        seed: options.seed,
        privacy: PrivacyPolicy {
            raw_queries_committed: false,
            raw_note_snippets_committed: false,
            path_values_committed: false,
            query_material: "Samples contain only per-artifact salted hashes, redacted labels, coverage metadata, and source-count hints.".to_string(),
        },
        totals,
        coverage,
        samples,
        warnings: collector.warnings.clone(),
    }
}

fn private_query_lines_from_collector(
    collector: &CorpusCollector,
    samples_per_class: usize,
) -> Vec<String> {
    let mut queries = Vec::new();
    for query_class in QUERY_CLASSES {
        queries.extend(
            collector
                .select_samples(query_class, samples_per_class)
                .into_iter()
                .map(|candidate| candidate.raw_query),
        );
    }
    queries
}

fn collect_candidates(
    vault_root: &Path,
    seed: u64,
    samples_per_class: usize,
    artifact_salt: &str,
) -> io::Result<CorpusCollector> {
    let mut collector = CorpusCollector::default();
    visit_vault(vault_root, vault_root, seed, artifact_salt, &mut collector)?;

    for query_class in QUERY_CLASSES {
        collector.ensure_zero_candidates(query_class, samples_per_class.max(10));
        collector.finalize_class(query_class);
    }

    Ok(collector)
}

#[derive(Default)]
struct CorpusCollector {
    by_class: BTreeMap<String, BTreeMap<String, Candidate>>,
    warnings: Vec<String>,
}

impl CorpusCollector {
    fn add(
        &mut self,
        query_class: &str,
        raw_query: &str,
        source_hash: &str,
        mut coverage: BTreeSet<String>,
        file_stem_candidate: bool,
    ) {
        let raw_query = normalize_query(raw_query);
        if raw_query.is_empty() {
            return;
        }

        add_text_coverage(&raw_query, &mut coverage);

        let class_candidates = self.by_class.entry(query_class.to_string()).or_default();
        let candidate = class_candidates
            .entry(raw_query.clone())
            .or_insert_with(|| Candidate::new(query_class, &raw_query));
        candidate.source_count += 1;
        if !candidate
            .source_hashes
            .iter()
            .any(|hash| hash == source_hash)
        {
            candidate.source_hashes.push(source_hash.to_string());
            candidate.source_hashes.sort();
            candidate.source_hashes.truncate(5);
        }
        candidate.coverage.extend(coverage);
        candidate.file_stem_candidate |= file_stem_candidate;
    }

    fn add_synthetic_zero(&mut self, query_class: &str, index: usize) {
        let raw_query = format!("__codex_zero_result_{query_class}_{index:04}__");
        let mut coverage = BTreeSet::from(["zero_result".to_string()]);
        add_text_coverage(&raw_query, &mut coverage);

        let class_candidates = self.by_class.entry(query_class.to_string()).or_default();
        class_candidates
            .entry(raw_query.clone())
            .or_insert_with(|| {
                let mut candidate = Candidate::new(query_class, &raw_query);
                candidate.coverage = coverage;
                candidate
            });
    }

    fn ensure_zero_candidates(&mut self, query_class: &str, count: usize) {
        for index in 0..count {
            self.add_synthetic_zero(query_class, index);
        }
    }

    fn finalize_class(&mut self, query_class: &str) {
        let Some(class_candidates) = self.by_class.get_mut(query_class) else {
            return;
        };

        for candidate in class_candidates.values_mut() {
            if candidate.source_count >= 10 {
                candidate.coverage.insert("many_result".to_string());
            }

            if candidate.file_stem_candidate && candidate.source_count > 1 {
                candidate.coverage.insert("duplicate_basename".to_string());
            }
        }
    }

    fn select_samples(&self, query_class: &str, samples_per_class: usize) -> Vec<Candidate> {
        let Some(class_candidates) = self.by_class.get(query_class) else {
            return Vec::new();
        };

        let mut ordered: Vec<_> = class_candidates.values().cloned().collect();
        ordered.sort_by(|left, right| {
            candidate_sort_key(left)
                .cmp(&candidate_sort_key(right))
                .then_with(|| left.raw_query.cmp(&right.raw_query))
        });

        let mut selected = Vec::new();
        let mut used_hashes = BTreeSet::new();

        for required in REQUIRED_COVERAGE {
            if let Some(candidate) = ordered
                .iter()
                .find(|candidate| candidate.coverage.contains(required))
            {
                let hash = stable_hash(candidate.raw_query.as_bytes());
                if used_hashes.insert(hash) {
                    selected.push(candidate.clone());
                }
            }
        }

        for candidate in ordered {
            if selected.len() >= samples_per_class {
                break;
            }

            let hash = stable_hash(candidate.raw_query.as_bytes());
            if used_hashes.insert(hash) {
                selected.push(candidate);
            }
        }

        selected.truncate(samples_per_class);
        selected
    }
}

fn visit_vault(
    vault_root: &Path,
    dir: &Path,
    seed: u64,
    artifact_salt: &str,
    collector: &mut CorpusCollector,
) -> io::Result<()> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(_) if dir != vault_root => {
            collector.warnings.push(format!(
                "read_dir_failed:{}",
                path_hash(vault_root, dir, artifact_salt)
            ));
            return Ok(());
        }
        Err(error) => return Err(error),
    };

    for entry_result in entries {
        let entry = match entry_result {
            Ok(entry) => entry,
            Err(error) => {
                collector
                    .warnings
                    .push(format!("read_dir_entry_failed:{:?}", error.kind()));
                continue;
            }
        };
        let path = entry.path();
        let metadata = match fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(_) => {
                collector.warnings.push(format!(
                    "metadata_failed:{}",
                    path_hash(vault_root, &path, artifact_salt)
                ));
                continue;
            }
        };
        let file_type = metadata.file_type();

        if file_type.is_symlink() {
            continue;
        }

        if file_type.is_dir() {
            if path.file_name().and_then(OsStr::to_str) == Some(".obsidian") {
                continue;
            }
            visit_vault(vault_root, &path, seed, artifact_salt, collector)?;
            continue;
        }

        if !file_type.is_file() || !is_markdown_path(&path) {
            continue;
        }

        collect_markdown_file(vault_root, &path, seed, artifact_salt, collector);
    }

    Ok(())
}

fn collect_markdown_file(
    vault_root: &Path,
    path: &Path,
    seed: u64,
    artifact_salt: &str,
    collector: &mut CorpusCollector,
) {
    let source_hash = path_hash(vault_root, path, artifact_salt);
    collect_file_name_candidates(path, &source_hash, collector);

    let Ok(bytes) = fs::read(path) else {
        collector
            .warnings
            .push(format!("read_failed:{}", source_hash));
        return;
    };

    let text = String::from_utf8_lossy(&bytes);
    collect_body_candidates(&text, &source_hash, seed, collector);
    collect_backlink_candidates(&text, &source_hash, collector);
    collect_tag_candidates(&text, &source_hash, collector);
    collect_property_candidates(&text, &source_hash, collector);
}

fn collect_file_name_candidates(path: &Path, source_hash: &str, collector: &mut CorpusCollector) {
    let Some(stem) = path.file_stem().and_then(OsStr::to_str) else {
        return;
    };

    collector.add("file_name", stem, source_hash, BTreeSet::new(), true);

    for term in tokenize(stem).into_iter().take(12) {
        collector.add("file_name", &term, source_hash, BTreeSet::new(), false);
    }

    for phrase in adjacent_phrases(&tokenize(stem), 4) {
        collector.add(
            "file_name",
            &phrase,
            source_hash,
            BTreeSet::from(["phrase".to_string()]),
            false,
        );
    }
}

fn collect_body_candidates(
    text: &str,
    source_hash: &str,
    seed: u64,
    collector: &mut CorpusCollector,
) {
    let tokens = tokenize_limited(text, 600);
    for token in tokens.iter().take(600) {
        if should_track_body_candidate(token, seed) {
            collector.add("body", token, source_hash, BTreeSet::new(), false);
        }
    }

    for phrase in adjacent_phrases(&tokens, 24) {
        if should_track_body_phrase(&phrase, seed) {
            collector.add(
                "body",
                &phrase,
                source_hash,
                BTreeSet::from(["phrase".to_string()]),
                false,
            );
        }
    }
}

fn collect_backlink_candidates(text: &str, source_hash: &str, collector: &mut CorpusCollector) {
    for target in wikilink_targets(text) {
        collector.add("backlink", &target, source_hash, BTreeSet::new(), false);
    }
}

fn collect_tag_candidates(text: &str, source_hash: &str, collector: &mut CorpusCollector) {
    for tag in inline_tags(text) {
        collector.add("tag", &tag, source_hash, BTreeSet::new(), false);
    }

    if let Some(frontmatter) = frontmatter_block(text) {
        for tag in frontmatter_tags(frontmatter) {
            collector.add("tag", &tag, source_hash, BTreeSet::new(), false);
        }
    }
}

fn collect_property_candidates(text: &str, source_hash: &str, collector: &mut CorpusCollector) {
    let Some(frontmatter) = frontmatter_block(text) else {
        return;
    };

    for property in frontmatter_properties(frontmatter) {
        collector.add("property", &property, source_hash, BTreeSet::new(), false);
    }
}

fn tokenize(text: &str) -> Vec<String> {
    tokenize_limited(text, usize::MAX)
}

fn tokenize_limited(text: &str, max_tokens: usize) -> Vec<String> {
    if max_tokens == 0 {
        return Vec::new();
    }

    let mut tokens = Vec::new();
    let mut current = String::new();

    for ch in text.chars() {
        if is_token_char(ch) {
            current.extend(ch.to_lowercase());
        } else if !current.is_empty() {
            push_token(&mut tokens, &mut current);
            if tokens.len() >= max_tokens {
                return tokens;
            }
        }
    }

    if !current.is_empty() {
        push_token(&mut tokens, &mut current);
    }

    tokens
}

fn push_token(tokens: &mut Vec<String>, current: &mut String) {
    let char_count = current.chars().count();
    if (2..=48).contains(&char_count) && current.chars().any(|ch| ch.is_alphabetic()) {
        tokens.push(std::mem::take(current));
    } else {
        current.clear();
    }
}

fn adjacent_phrases(tokens: &[String], limit: usize) -> Vec<String> {
    tokens
        .windows(2)
        .filter_map(|window| {
            let left = window.first()?;
            let right = window.get(1)?;
            if left == right {
                return None;
            }
            Some(format!("{left} {right}"))
        })
        .take(limit)
        .collect()
}

fn wikilink_targets(text: &str) -> Vec<String> {
    let mut targets = Vec::new();
    let mut rest = text;

    while let Some(start) = rest.find("[[") {
        let after_start = &rest[start + 2..];
        let Some(end) = after_start.find("]]") else {
            break;
        };

        let raw = &after_start[..end];
        let target = raw
            .split('|')
            .next()
            .unwrap_or(raw)
            .split('#')
            .next()
            .unwrap_or(raw)
            .trim();
        if !target.is_empty() {
            targets.push(target.to_string());
        }

        rest = &after_start[end + 2..];
    }

    targets
}

fn inline_tags(text: &str) -> Vec<String> {
    text.lines().flat_map(inline_tags_in_line).collect()
}

fn inline_tags_in_line(line: &str) -> Vec<String> {
    let trimmed_start = line.trim_start();
    if trimmed_start.starts_with('#')
        && trimmed_start
            .chars()
            .find(|ch| *ch != '#')
            .is_some_and(char::is_whitespace)
    {
        return Vec::new();
    }

    let chars: Vec<(usize, char)> = line.char_indices().collect();
    let mut tags = Vec::new();

    for (position, (byte_index, ch)) in chars.iter().enumerate() {
        if *ch != '#' {
            continue;
        }

        let previous = position
            .checked_sub(1)
            .and_then(|index| chars.get(index))
            .map(|(_, ch)| *ch);
        if previous.is_some_and(|ch| ch.is_alphanumeric() || ch == '_') {
            continue;
        }

        let tag_tail = &line[*byte_index + ch.len_utf8()..];
        let tag: String = tag_tail
            .chars()
            .take_while(|ch| ch.is_alphanumeric() || matches!(ch, '_' | '-' | '/'))
            .collect();
        if tag.chars().any(|ch| ch.is_alphabetic()) {
            tags.push(tag);
        }
    }

    tags
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

fn frontmatter_tags(frontmatter: &str) -> Vec<String> {
    frontmatter_properties(frontmatter)
        .into_iter()
        .filter_map(|property| property.strip_prefix("tags=").map(ToString::to_string))
        .collect()
}

fn frontmatter_properties(frontmatter: &str) -> Vec<String> {
    let mut properties = Vec::new();
    let mut current_key: Option<String> = None;

    for line in frontmatter.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }

        if let Some(item) = trimmed.strip_prefix("- ") {
            if let Some(key) = current_key.as_deref() {
                for value in split_property_values(item) {
                    properties.push(format!("{key}={value}"));
                }
            }
            continue;
        }

        let Some((key, value)) = trimmed.split_once(':') else {
            current_key = None;
            continue;
        };

        let key = normalize_query(key);
        if key.is_empty() {
            current_key = None;
            continue;
        }

        current_key = Some(key.clone());
        properties.push(key.clone());

        for value in split_property_values(value) {
            properties.push(format!("{key}={value}"));
        }
    }

    properties
}

fn split_property_values(value: &str) -> Vec<String> {
    let value = value.trim().trim_matches(['"', '\'']);
    if value.is_empty() {
        return Vec::new();
    }

    let values: Vec<_> = if value.starts_with('[') && value.ends_with(']') {
        value
            .trim_matches(['[', ']'])
            .split(',')
            .map(normalize_query)
            .filter(|part| !part.is_empty())
            .collect()
    } else {
        vec![normalize_query(value)]
    };

    values
        .into_iter()
        .filter(|value| value.chars().count() <= 80)
        .collect()
}

fn should_track_body_candidate(token: &str, seed: u64) -> bool {
    has_korean_cjk(token) || token.chars().count() <= 3 || hash_bucket(token, seed, 257) == 0
}

fn should_track_body_phrase(phrase: &str, seed: u64) -> bool {
    has_korean_cjk(phrase) || hash_bucket(phrase, seed, 251) == 0
}

fn hash_bucket(value: &str, seed: u64, modulo: u64) -> u64 {
    let hash = u64::from_str_radix(&stable_hash(value.as_bytes())[..16], 16).unwrap_or(0);
    (hash ^ seed) % modulo
}

fn add_text_coverage(raw_query: &str, coverage: &mut BTreeSet<String>) {
    let char_count = raw_query.chars().count();

    if raw_query.chars().any(|ch| ch.is_ascii_alphabetic()) {
        coverage.insert("english".to_string());
    }
    if has_korean_cjk(raw_query) {
        coverage.insert("korean_cjk".to_string());
    }
    if char_count <= 3 {
        coverage.insert("short".to_string());
    }
    if raw_query.split_whitespace().count() > 1 {
        coverage.insert("phrase".to_string());
    }
    if raw_query.chars().any(char::is_whitespace) {
        coverage.insert("space".to_string());
    }
}

fn sample_from_candidate(index: usize, candidate: Candidate, artifact_salt: &str) -> QuerySample {
    let query_hash = salted_private_hash(artifact_salt, candidate.raw_query.as_bytes());
    let mut coverage: Vec<_> = candidate.coverage.into_iter().collect();
    coverage.sort();
    let expected_result_shape = expected_result_shape(candidate.source_count, &coverage);
    QuerySample {
        id: format!("{}-{index:04}", candidate.query_class),
        query_class: candidate.query_class,
        redacted_display: format!(
            "<{}:{}:{}>",
            query_hash.get(..8).unwrap_or(&query_hash),
            coverage
                .first()
                .map(String::as_str)
                .unwrap_or("uncategorized"),
            expected_result_shape
        ),
        query_hash,
        coverage,
        expected_result_shape,
        source_count_hint: candidate.source_count,
        source_hashes: candidate.source_hashes,
    }
}

fn expected_result_shape(source_count: u64, coverage: &[String]) -> String {
    if coverage.iter().any(|item| item == "zero_result") {
        "zero".to_string()
    } else if source_count == 1 {
        "single".to_string()
    } else if source_count >= 10 {
        "many".to_string()
    } else {
        "few".to_string()
    }
}

fn coverage_for(samples: &[Candidate]) -> Vec<String> {
    let mut coverage = BTreeSet::new();
    for sample in samples {
        coverage.extend(sample.coverage.iter().cloned());
    }
    coverage.into_iter().collect()
}

fn candidate_sort_key(candidate: &Candidate) -> String {
    stable_hash(format!("{}:{}", candidate.query_class, candidate.raw_query).as_bytes())
}

fn normalize_query(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn path_hash(vault_root: &Path, path: &Path, artifact_salt: &str) -> String {
    let relative_path = path.strip_prefix(vault_root).unwrap_or(path);
    salted_private_hash(artifact_salt, relative_path.to_string_lossy().as_bytes())
}

fn is_token_char(ch: char) -> bool {
    ch.is_alphanumeric() || matches!(ch, '_' | '-')
}

fn has_korean_cjk(value: &str) -> bool {
    value.chars().any(|ch| {
        matches!(
            ch as u32,
            0x1100..=0x11FF
                | 0x3130..=0x318F
                | 0xAC00..=0xD7AF
                | 0x3400..=0x4DBF
                | 0x4E00..=0x9FFF
                | 0x3040..=0x30FF
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn generates_redacted_samples_with_salted_private_identifiers() {
        let dir = tempdir().expect("tempdir");
        fs::create_dir(dir.path().join("a")).expect("dir a");
        fs::create_dir(dir.path().join("b")).expect("dir b");
        fs::write(
            dir.path().join("a").join("Plan.md"),
            "---\ntags: [alpha, 한글태그]\nstatus: draft\nowner: team\n---\n# Title\nBody has alpha beta and 한국어 문장.\n[[Target Note]] #inline/tag\n",
        )
        .expect("write a");
        fs::write(
            dir.path().join("b").join("Plan.md"),
            "---\ntags:\n  - beta\nstatus: done\n---\nSecond body with repeated alpha beta.\n[[Target Note]]\n",
        )
        .expect("write b");
        fs::write(
            dir.path().join("한글 노트.md"),
            "---\ncategory: 연구\n---\n한국어 본문과 [link](asset.pdf).\n",
        )
        .expect("write korean");

        let options = QueryCorpusOptions {
            vault_root: dir.path().to_path_buf(),
            samples_per_class: 10,
            seed: 42,
        };
        let first = generate_query_corpus(&options).expect("first");
        let second = generate_query_corpus(&options).expect("second");

        for query_class in QUERY_CLASSES {
            assert_eq!(first.totals.get(query_class), Some(&10));
            assert_eq!(
                first.totals.get(query_class),
                second.totals.get(query_class)
            );
        }
        assert!(first.coverage["file_name"].contains(&"duplicate_basename".to_string()));
        assert!(first.coverage["body"].contains(&"korean_cjk".to_string()));
        assert!(first.coverage["tag"].contains(&"zero_result".to_string()));
        assert_eq!(first.vault.root_name, "redacted-vault");
        assert_eq!(first.vault.root_hash, "redacted");
        assert_ne!(first.samples[0].query_hash, second.samples[0].query_hash);
        let first_source_sample = first
            .samples
            .iter()
            .find(|sample| !sample.source_hashes.is_empty())
            .expect("source sample");
        let second_source_sample = second
            .samples
            .iter()
            .find(|sample| sample.id == first_source_sample.id)
            .expect("matching source sample");
        assert_ne!(
            first_source_sample.source_hashes,
            second_source_sample.source_hashes
        );
    }

    #[test]
    fn serialized_corpus_does_not_contain_raw_private_values() {
        let dir = tempdir().expect("tempdir");
        fs::write(
            dir.path().join("Secret Project.md"),
            "---\nprivate_key: private-value\n---\nsecret body phrase\n[[Secret Target]] #secret-tag\n",
        )
        .expect("write");

        let corpus = generate_query_corpus(&QueryCorpusOptions {
            vault_root: dir.path().to_path_buf(),
            samples_per_class: 5,
            seed: 7,
        })
        .expect("corpus");
        let json = serde_json::to_string(&corpus).expect("json");

        assert!(!json.contains("secret body phrase"));
        assert!(!json.contains("Secret Project"));
        assert!(!json.contains("private-value"));
        assert!(!json.contains("Secret Target"));
        assert!(!json.contains("secret-tag"));
        assert!(!json.contains(dir.path().to_string_lossy().as_ref()));
        assert!(json.contains("\"root_name\":\"redacted-vault\""));
        assert!(json.contains("query_hash"));
    }

    #[test]
    fn generates_private_query_lines_without_redaction() {
        let dir = tempdir().expect("tempdir");
        fs::write(
            dir.path().join("Home Note.md"),
            "# Home Note\nBody contains apple banana.\n#project/native",
        )
        .expect("note");

        let queries = generate_private_query_lines(&QueryCorpusOptions {
            vault_root: dir.path().to_path_buf(),
            samples_per_class: 10,
            seed: 7,
        })
        .expect("private queries");

        assert!(queries.iter().any(|query| query == "Home Note"));
        assert!(queries.iter().all(|query| !query.starts_with('<')));
    }

    #[test]
    fn bundle_contains_redacted_corpus_and_private_queries() {
        let dir = tempdir().expect("tempdir");
        fs::write(
            dir.path().join("Home Note.md"),
            "# Home Note\nBody contains apple banana.\n#project/native",
        )
        .expect("note");

        let bundle = generate_query_corpus_bundle(&QueryCorpusOptions {
            vault_root: dir.path().to_path_buf(),
            samples_per_class: 10,
            seed: 7,
        })
        .expect("bundle");

        assert_eq!(
            bundle.private_query_lines.len(),
            bundle.corpus.samples.len()
        );
        assert!(
            bundle
                .private_query_lines
                .iter()
                .any(|query| query == "Home Note")
        );
        assert!(
            bundle
                .corpus
                .samples
                .iter()
                .all(|sample| sample.redacted_display.starts_with('<'))
        );
    }
}
