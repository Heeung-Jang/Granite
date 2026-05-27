use crate::{redacted_private_value, stable_hash};
use serde::Serialize;
use std::collections::BTreeMap;
use std::error::Error;
use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;
use vault_engine::attachments::{
    AttachmentReferenceSource, AttachmentRejectReason, AttachmentResolutionState,
};
use vault_engine::index::{
    AttachmentRecord, FileRecord, HeadingRecord, IndexedFileRecords, LinkEdgeRecord, MetadataStore,
    PropertyRecord, TagRecord, TagSource, slugify_heading,
};
use vault_engine::parser::{MarkdownLink, ParsedMarkdown, WikiLink, parse_markdown};
use vault_engine::paths::{VaultRoot, lookup_key, normalize_relative_path};
use vault_engine::read_api::expected_read_schema_metadata;
use vault_engine::scanner::{ScanEntry, ScanEntryKind, ScanSummary, classify_file, scan_vault};
use vault_engine::sqlite_fts::SearchDocument;
use vault_engine::tantivy_search::TantivySearchIndex;

#[derive(Debug, Clone)]
pub struct ReadIndexMaterializeOptions {
    pub vault_root: PathBuf,
    pub metadata_path: PathBuf,
    pub tantivy_path: PathBuf,
    pub force: bool,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct ReadIndexMaterializeArtifact {
    pub schema_version: u32,
    pub tool: String,
    pub vault_root_hash: String,
    pub metadata_path_hash: String,
    pub tantivy_path_hash: String,
    pub markdown_files: usize,
    pub attachment_files: usize,
    pub other_files: usize,
    pub indexed_files: usize,
    pub errored_files: usize,
    pub links: usize,
    pub tags: usize,
    pub properties: usize,
    pub headings: usize,
    pub attachments: usize,
    pub duration_ms: f64,
    pub privacy: ReadIndexMaterializePrivacy,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct ReadIndexMaterializePrivacy {
    pub raw_note_bodies_committed: bool,
    pub raw_paths_committed: bool,
    pub absolute_paths_committed: bool,
}

#[derive(Debug, Default)]
struct IndexStats {
    indexed_files: usize,
    errored_files: usize,
    links: usize,
    tags: usize,
    properties: usize,
    headings: usize,
    attachments: usize,
}

pub fn materialize_read_index(
    options: &ReadIndexMaterializeOptions,
) -> Result<ReadIndexMaterializeArtifact, Box<dyn Error>> {
    let started = Instant::now();
    let root = VaultRoot::open(&options.vault_root)?;
    prepare_outputs(options)?;
    let scan = scan_vault(&root)
        .map_err(|error| std::io::Error::other(format!("vault scan failed: {error:?}")))?;
    let resolver = TargetResolver::new(&scan);
    let mut store = MetadataStore::open(&options.metadata_path, &expected_read_schema_metadata())?;
    let mut records = Vec::with_capacity(scan.entries.len());
    let mut stats = IndexStats::default();

    for (index, entry) in scan.entries.iter().enumerate() {
        if index > 0 && index.is_multiple_of(5_000) {
            eprintln!("materialize-read-index: parsed {index} files");
        }
        let mut file = FileRecord::from_scan_entry(entry, 0);
        match entry.kind {
            ScanEntryKind::Markdown => {
                match fs::read_to_string(root.canonical_root().join(&entry.relative_path)) {
                    Ok(contents) => {
                        let parsed = parse_markdown(&contents);
                        let links = link_records(&file, entry, &parsed, &resolver);
                        let tags = tag_records(&file, &parsed);
                        let properties = property_records(&file, &parsed);
                        let headings = heading_records(&file, &parsed);
                        let attachments = attachment_records(entry, &file, &parsed, &resolver);
                        file.mark_parsed(stable_hash(contents.as_bytes()));
                        file.mark_search_indexed();
                        stats.indexed_files += 1;
                        stats.links += links.len();
                        stats.tags += tags.len();
                        stats.properties += properties.len();
                        stats.headings += headings.len();
                        stats.attachments += attachments.len();
                        records.push(IndexedFileRecords {
                            file,
                            links,
                            tags,
                            properties,
                            headings,
                            attachments,
                        });
                    }
                    Err(error) => {
                        file.mark_error(format!("io:{:?}", error.kind()));
                        records.push(IndexedFileRecords {
                            file,
                            links: Vec::new(),
                            tags: Vec::new(),
                            properties: Vec::new(),
                            headings: Vec::new(),
                            attachments: Vec::new(),
                        });
                        stats.errored_files += 1;
                    }
                }
            }
            ScanEntryKind::Attachment | ScanEntryKind::Other => {
                records.push(IndexedFileRecords {
                    file,
                    links: Vec::new(),
                    tags: Vec::new(),
                    properties: Vec::new(),
                    headings: Vec::new(),
                    attachments: Vec::new(),
                });
                stats.indexed_files += 1;
            }
        }
    }
    eprintln!(
        "materialize-read-index: writing {} metadata records",
        records.len()
    );
    store.bulk_load_file_records(&records)?;
    drop(store);

    eprintln!("materialize-read-index: writing Tantivy documents");
    let mut search = TantivySearchIndex::open_in_dir(&options.tantivy_path)?;
    search.replace_documents_from_result_iter(SearchDocumentIter::new(&root, &scan.entries))?;
    drop(search);

    Ok(ReadIndexMaterializeArtifact {
        schema_version: 1,
        tool: "vault-profiler materialize-read-index".to_string(),
        vault_root_hash: redacted_private_value(),
        metadata_path_hash: redacted_private_value(),
        tantivy_path_hash: redacted_private_value(),
        markdown_files: scan.markdown_files,
        attachment_files: scan.attachment_files,
        other_files: scan.other_files,
        indexed_files: stats.indexed_files,
        errored_files: stats.errored_files,
        links: stats.links,
        tags: stats.tags,
        properties: stats.properties,
        headings: stats.headings,
        attachments: stats.attachments,
        duration_ms: rounded_ms(started.elapsed().as_secs_f64() * 1_000.0),
        privacy: ReadIndexMaterializePrivacy {
            raw_note_bodies_committed: false,
            raw_paths_committed: false,
            absolute_paths_committed: false,
        },
    })
}

fn prepare_outputs(options: &ReadIndexMaterializeOptions) -> Result<(), Box<dyn Error>> {
    if options.force {
        if options.metadata_path.exists() {
            fs::remove_file(&options.metadata_path)?;
        }
        if options.tantivy_path.exists() {
            fs::remove_dir_all(&options.tantivy_path)?;
        }
    } else {
        if options.metadata_path.exists() {
            return Err("metadata index already exists; pass --force to replace it".into());
        }
        if options.tantivy_path.exists() && fs::read_dir(&options.tantivy_path)?.next().is_some() {
            return Err("Tantivy index already exists; pass --force to replace it".into());
        }
    }

    if let Some(parent) = options.metadata_path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::create_dir_all(&options.tantivy_path)?;
    Ok(())
}

fn link_records(
    file: &FileRecord,
    entry: &ScanEntry,
    parsed: &ParsedMarkdown,
    resolver: &TargetResolver,
) -> Vec<LinkEdgeRecord> {
    let mut links = Vec::new();
    for link in &parsed.wikilinks {
        links.push(wiki_link_record(file, link, false, resolver));
    }
    for embed in &parsed.embeds {
        links.push(wiki_link_record(file, embed, true, resolver));
    }
    for markdown_link in parsed.markdown_links.iter().filter(|link| !link.image) {
        if let Some(record) = markdown_link_record(file, entry, markdown_link, resolver) {
            links.push(record);
        }
    }
    links
}

fn wiki_link_record(
    file: &FileRecord,
    link: &WikiLink,
    is_embed: bool,
    resolver: &TargetResolver,
) -> LinkEdgeRecord {
    LinkEdgeRecord {
        source_file_id: file.file_id.clone(),
        target_text: link.target.clone(),
        resolved_target_file_id: resolver.resolve_wiki(&link.target),
        heading: link.heading.clone(),
        alias: link.alias.clone(),
        is_embed,
    }
}

fn markdown_link_record(
    file: &FileRecord,
    entry: &ScanEntry,
    link: &MarkdownLink,
    resolver: &TargetResolver,
) -> Option<LinkEdgeRecord> {
    if is_remote_or_rejected(&link.target) {
        return None;
    }
    let target_without_heading = link.target.split('#').next().unwrap_or(&link.target);
    if classify_file(Path::new(target_without_heading)) == ScanEntryKind::Attachment {
        return None;
    }
    Some(LinkEdgeRecord {
        source_file_id: file.file_id.clone(),
        target_text: link.target.clone(),
        resolved_target_file_id: resolver
            .resolve_markdown(&entry.relative_path, target_without_heading),
        heading: link
            .target
            .split_once('#')
            .map(|(_, heading)| heading.to_string()),
        alias: Some(link.text.clone()),
        is_embed: false,
    })
}

fn tag_records(file: &FileRecord, parsed: &ParsedMarkdown) -> Vec<TagRecord> {
    parsed
        .tags
        .iter()
        .map(|tag| TagRecord {
            file_id: file.file_id.clone(),
            tag: tag.clone(),
            source: TagSource::Inline,
        })
        .collect()
}

fn property_records(file: &FileRecord, parsed: &ParsedMarkdown) -> Vec<PropertyRecord> {
    parsed
        .properties
        .iter()
        .map(|(key, value)| PropertyRecord::from_property_value(file.file_id.clone(), key, value))
        .collect()
}

fn heading_records(file: &FileRecord, parsed: &ParsedMarkdown) -> Vec<HeadingRecord> {
    parsed
        .headings
        .iter()
        .map(|heading| HeadingRecord {
            file_id: file.file_id.clone(),
            slug: slugify_heading(&heading.text),
            title: heading.text.clone(),
            level: heading.level,
            byte_offset: None,
        })
        .collect()
}

fn attachment_records(
    entry: &ScanEntry,
    file: &FileRecord,
    parsed: &ParsedMarkdown,
    resolver: &TargetResolver,
) -> Vec<AttachmentRecord> {
    let mut records = Vec::new();
    for embed in &parsed.embeds {
        records.push(AttachmentRecord {
            source_file_id: file.file_id.clone(),
            source: AttachmentReferenceSource::WikiEmbed,
            raw_target: embed.target.clone(),
            state: attachment_state_for_wiki(&embed.target, resolver),
        });
    }
    for link in parsed.markdown_links.iter().filter(|link| {
        link.image
            || classify_file(Path::new(
                link.target.split('#').next().unwrap_or(&link.target),
            )) == ScanEntryKind::Attachment
    }) {
        let target = link.target.split('#').next().unwrap_or(&link.target);
        records.push(AttachmentRecord {
            source_file_id: file.file_id.clone(),
            source: if link.image {
                AttachmentReferenceSource::MarkdownImage
            } else {
                AttachmentReferenceSource::MarkdownLink
            },
            raw_target: link.target.clone(),
            state: attachment_state_for_markdown(&entry.relative_path, target, resolver),
        });
    }
    records
}

fn attachment_state_for_wiki(target: &str, resolver: &TargetResolver) -> AttachmentResolutionState {
    if let Some(state) = rejected_or_remote_attachment_state(target) {
        return state;
    }
    resolver
        .resolve_wiki_path(target)
        .map(|relative_path| AttachmentResolutionState::Resolved { relative_path })
        .unwrap_or(AttachmentResolutionState::Missing)
}

fn attachment_state_for_markdown(
    source_path: &Path,
    target: &str,
    resolver: &TargetResolver,
) -> AttachmentResolutionState {
    if let Some(state) = rejected_or_remote_attachment_state(target) {
        return state;
    }
    resolver
        .resolve_markdown_path(source_path, target)
        .map(|relative_path| AttachmentResolutionState::Resolved { relative_path })
        .unwrap_or(AttachmentResolutionState::Missing)
}

fn rejected_or_remote_attachment_state(target: &str) -> Option<AttachmentResolutionState> {
    let trimmed = target.trim();
    if trimmed.contains("://") {
        return Some(AttachmentResolutionState::Remote);
    }
    if trimmed.contains('\0') {
        return Some(AttachmentResolutionState::Rejected(
            AttachmentRejectReason::ContainsNul,
        ));
    }
    if trimmed.starts_with('/') {
        return Some(AttachmentResolutionState::Rejected(
            AttachmentRejectReason::AbsolutePath,
        ));
    }
    if trimmed == "~" || trimmed.starts_with("~/") {
        return Some(AttachmentResolutionState::Rejected(
            AttachmentRejectReason::TildePrefix,
        ));
    }
    None
}

struct TargetResolver {
    exact: BTreeMap<String, String>,
    relative_paths: BTreeMap<String, PathBuf>,
    no_extension: BTreeMap<String, String>,
    basename: BTreeMap<String, Vec<String>>,
}

impl TargetResolver {
    fn new(scan: &ScanSummary) -> Self {
        let mut resolver = Self {
            exact: BTreeMap::new(),
            relative_paths: BTreeMap::new(),
            no_extension: BTreeMap::new(),
            basename: BTreeMap::new(),
        };

        for entry in &scan.entries {
            let file_id = lookup_key(&entry.relative_path);
            resolver.exact.insert(file_id.clone(), file_id.clone());
            resolver
                .relative_paths
                .insert(file_id.clone(), entry.relative_path.clone());
            if matches!(entry.kind, ScanEntryKind::Markdown) {
                let no_extension = entry.relative_path.with_extension("");
                resolver
                    .no_extension
                    .insert(lookup_key(no_extension), file_id.clone());
            }
            if let Some(stem) = entry.relative_path.file_stem().and_then(OsStr::to_str) {
                resolver
                    .basename
                    .entry(stem.to_lowercase())
                    .or_default()
                    .push(file_id);
            }
        }

        resolver
    }

    fn resolve_wiki(&self, target: &str) -> Option<String> {
        if is_remote_or_rejected(target) {
            return None;
        }
        let normalized = normalize_relative_path(target).ok()?;
        self.resolve_path_like(&normalized)
            .or_else(|| self.resolve_basename(target))
    }

    fn resolve_wiki_path(&self, target: &str) -> Option<PathBuf> {
        let file_id = self.resolve_wiki(target)?;
        self.relative_paths.get(&file_id).cloned()
    }

    fn resolve_markdown(&self, source_path: &Path, target: &str) -> Option<String> {
        if target.trim().is_empty() || is_remote_or_rejected(target) {
            return None;
        }
        let joined = source_path
            .parent()
            .unwrap_or_else(|| Path::new(""))
            .join(target);
        let normalized = normalize_relative_path(&joined.to_string_lossy()).ok()?;
        self.resolve_path_like(&normalized)
            .or_else(|| self.resolve_basename(target))
    }

    fn resolve_markdown_path(&self, source_path: &Path, target: &str) -> Option<PathBuf> {
        let file_id = self.resolve_markdown(source_path, target)?;
        self.relative_paths.get(&file_id).cloned()
    }

    fn resolve_path_like(&self, path: &Path) -> Option<String> {
        let exact = lookup_key(path);
        self.exact
            .get(&exact)
            .cloned()
            .or_else(|| self.no_extension.get(&exact).cloned())
            .or_else(|| {
                self.exact
                    .get(&lookup_key(path.with_extension("md")))
                    .cloned()
            })
            .or_else(|| {
                self.exact
                    .get(&lookup_key(path.with_extension("markdown")))
                    .cloned()
            })
    }

    fn resolve_basename(&self, target: &str) -> Option<String> {
        let stem = Path::new(target)
            .file_stem()
            .and_then(OsStr::to_str)
            .unwrap_or(target)
            .to_lowercase();
        let matches = self.basename.get(&stem)?;
        (matches.len() == 1).then(|| matches[0].clone())
    }
}

struct SearchDocumentIter<'a> {
    root: &'a VaultRoot,
    markdown_entries: Vec<&'a ScanEntry>,
    index: usize,
}

impl<'a> SearchDocumentIter<'a> {
    fn new(root: &'a VaultRoot, entries: &'a [ScanEntry]) -> Self {
        Self {
            root,
            markdown_entries: entries
                .iter()
                .filter(|entry| entry.kind == ScanEntryKind::Markdown)
                .collect(),
            index: 0,
        }
    }
}

impl Iterator for SearchDocumentIter<'_> {
    type Item = Result<SearchDocument, Box<dyn Error>>;

    fn next(&mut self) -> Option<Self::Item> {
        let entry = self.markdown_entries.get(self.index).copied()?;
        self.index += 1;
        Some(search_document(self.root, entry))
    }
}

fn search_document(root: &VaultRoot, entry: &ScanEntry) -> Result<SearchDocument, Box<dyn Error>> {
    let body = fs::read_to_string(root.canonical_root().join(&entry.relative_path))?;
    let parsed = parse_markdown(&body);
    Ok(SearchDocument {
        file_id: lookup_key(&entry.relative_path),
        path: entry.relative_path.to_string_lossy().to_string(),
        title: parsed
            .headings
            .first()
            .map(|heading| heading.text.clone())
            .or_else(|| {
                entry
                    .relative_path
                    .file_stem()
                    .and_then(OsStr::to_str)
                    .map(str::to_string)
            })
            .unwrap_or_else(|| entry.relative_path.to_string_lossy().to_string()),
        body,
    })
}

fn is_remote_or_rejected(target: &str) -> bool {
    let trimmed = target.trim();
    trimmed.is_empty()
        || trimmed.contains('\0')
        || trimmed.starts_with('/')
        || trimmed == "~"
        || trimmed.starts_with("~/")
        || trimmed.starts_with('#')
        || trimmed.contains("://")
        || trimmed.starts_with("obsidian:")
        || trimmed.starts_with("javascript:")
        || trimmed.starts_with("data:")
}

fn rounded_ms(value: f64) -> f64 {
    (value * 1_000.0).round() / 1_000.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;
    use vault_engine::read_api::{PageRequest, open_vault_read_api};

    #[test]
    fn materializes_fixture_read_index_for_read_api() {
        let dir = tempdir().expect("tempdir");
        let vault = dir.path().join("vault");
        let index = dir.path().join("index");
        fs::create_dir_all(vault.join("Folder")).expect("folder");
        fs::write(
            vault.join("Home.md"),
            "---\ntags: [alpha]\nstatus: active\n---\n# Home\n[[Folder/Target]]\n![Diagram](diagram.png)\n",
        )
        .expect("home");
        fs::write(
            vault.join("Folder").join("Target.md"),
            "# Target\n[[Home]]\n",
        )
        .expect("target");
        fs::write(vault.join("diagram.png"), "png").expect("attachment");

        let artifact = materialize_read_index(&ReadIndexMaterializeOptions {
            vault_root: vault,
            metadata_path: index.join("metadata.sqlite"),
            tantivy_path: index.join("tantivy"),
            force: true,
        })
        .expect("materialize");

        assert_eq!(artifact.markdown_files, 2);
        assert_eq!(artifact.attachment_files, 1);
        assert_eq!(artifact.links, 2);
        assert_eq!(artifact.properties, 2);
        assert_eq!(artifact.attachments, 1);
        assert_eq!(artifact.vault_root_hash, "redacted");
        assert_eq!(artifact.metadata_path_hash, "redacted");
        assert_eq!(artifact.tantivy_path_hash, "redacted");

        let api = open_vault_read_api(index.join("metadata.sqlite"), index.join("tantivy"))
            .expect("read api");
        let backlinks = api
            .backlinks_for_path("Folder/Target.md", PageRequest::new(0, 10))
            .expect("backlinks");
        assert_eq!(backlinks.items.len(), 1);
        let search = api
            .body_search("Home", PageRequest::new(0, 10))
            .expect("search");
        assert!(!search.items.is_empty());
    }

    #[test]
    fn refuses_existing_outputs_without_force() {
        let dir = tempdir().expect("tempdir");
        let metadata_path = dir.path().join("metadata.sqlite");
        let tantivy_path = dir.path().join("tantivy");
        fs::write(&metadata_path, "existing").expect("metadata");
        fs::create_dir_all(&tantivy_path).expect("tantivy");
        fs::write(tantivy_path.join("segment"), "existing").expect("tantivy file");

        let error = prepare_outputs(&ReadIndexMaterializeOptions {
            vault_root: dir.path().join("vault"),
            metadata_path,
            tantivy_path,
            force: false,
        })
        .expect_err("existing output should require force");

        assert!(error.to_string().contains("--force"));
    }
}
