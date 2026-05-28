use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::adapters::fs::path_resolver::VaultRoot;
use crate::core::document::{MarkdownLink, ParsedMarkdown, WikiLink};
use crate::core::paths::{PathError, lookup_key, normalize_relative_path};
use crate::core::scan::{ScanEntryKind, ScanSummary, classify_file};

pub use crate::core::attachments::{
    AttachmentReference, AttachmentReferenceSource, AttachmentRejectReason,
    AttachmentResolutionState, AttachmentSettings,
};

pub fn resolve_attachment_references(
    root: &VaultRoot,
    scan: &ScanSummary,
    note_path: &Path,
    parsed: &ParsedMarkdown,
    settings: &AttachmentSettings,
) -> Vec<AttachmentReference> {
    let resolver = AttachmentResolver::new(root, scan, settings);
    let mut references = Vec::new();

    for embed in &parsed.embeds {
        references.push(AttachmentReference {
            source: AttachmentReferenceSource::WikiEmbed,
            raw_target: embed.target.clone(),
            state: resolver.resolve_wiki_embed(embed),
        });
    }

    for link in parsed
        .markdown_links
        .iter()
        .filter(|link| is_markdown_attachment_candidate(link))
    {
        references.push(AttachmentReference {
            source: if link.image {
                AttachmentReferenceSource::MarkdownImage
            } else {
                AttachmentReferenceSource::MarkdownLink
            },
            raw_target: link.target.clone(),
            state: resolver.resolve_markdown_link(note_path, link),
        });
    }

    references
}

struct AttachmentResolver<'a> {
    root: &'a VaultRoot,
    settings: &'a AttachmentSettings,
    entries_by_path: BTreeMap<String, IndexedEntry>,
    attachments_by_name: BTreeMap<String, Vec<PathBuf>>,
}

#[derive(Debug, Clone)]
struct IndexedEntry {
    relative_path: PathBuf,
    kind: ScanEntryKind,
}

impl<'a> AttachmentResolver<'a> {
    fn new(root: &'a VaultRoot, scan: &ScanSummary, settings: &'a AttachmentSettings) -> Self {
        let mut entries_by_path = BTreeMap::new();
        let mut attachments_by_name: BTreeMap<String, Vec<PathBuf>> = BTreeMap::new();

        for entry in &scan.entries {
            entries_by_path.insert(
                lookup_key(&entry.relative_path),
                IndexedEntry {
                    relative_path: entry.relative_path.clone(),
                    kind: entry.kind,
                },
            );

            if entry.kind == ScanEntryKind::Attachment
                && let Some(file_name) = entry.relative_path.file_name()
            {
                attachments_by_name
                    .entry(lookup_key(Path::new(file_name)))
                    .or_default()
                    .push(entry.relative_path.clone());
            }
        }

        for candidates in attachments_by_name.values_mut() {
            candidates.sort();
        }

        Self {
            root,
            settings,
            entries_by_path,
            attachments_by_name,
        }
    }

    fn resolve_wiki_embed(&self, embed: &WikiLink) -> AttachmentResolutionState {
        let target = embed.target.trim();
        if let Some(state) = classify_url_target(target) {
            return state;
        }

        if let Some(folder) = &self.settings.attachment_folder
            && !has_path_separator(target)
        {
            let candidate = folder.join(target);
            let state = self.resolve_exact_relative(&candidate);
            if state != AttachmentResolutionState::Missing {
                return state;
            }
        }

        if !has_path_separator(target) {
            return self.resolve_by_basename(target);
        }

        self.resolve_exact_relative(Path::new(target))
    }

    fn resolve_markdown_link(
        &self,
        note_path: &Path,
        link: &MarkdownLink,
    ) -> AttachmentResolutionState {
        let target = link.target.trim();
        if let Some(state) = classify_url_target(target) {
            return state;
        }

        let target = target.split('#').next().unwrap_or(target);
        let relative_target = note_path
            .parent()
            .unwrap_or_else(|| Path::new(""))
            .join(target);
        self.resolve_exact_relative(&relative_target)
    }

    fn resolve_by_basename(&self, target: &str) -> AttachmentResolutionState {
        if classify_file(Path::new(target)) != ScanEntryKind::Attachment {
            return AttachmentResolutionState::Unsupported;
        }

        let key = lookup_key(target);
        match self.attachments_by_name.get(&key).map(Vec::as_slice) {
            Some([candidate]) => AttachmentResolutionState::Resolved {
                relative_path: candidate.clone(),
            },
            Some(candidates) if !candidates.is_empty() => AttachmentResolutionState::Duplicate {
                candidates: candidates.to_vec(),
            },
            _ => {
                let normalized = normalize_relative_path(target);
                match normalized {
                    Ok(_) => AttachmentResolutionState::Missing,
                    Err(error) => map_path_error(error),
                }
            }
        }
    }

    fn resolve_exact_relative(&self, target: &Path) -> AttachmentResolutionState {
        let target = target.to_string_lossy();
        let normalized = match normalize_relative_path(&target) {
            Ok(path) => path,
            Err(error) => return map_path_error(error),
        };

        if classify_file(&normalized) != ScanEntryKind::Attachment {
            return AttachmentResolutionState::Unsupported;
        }

        let key = lookup_key(&normalized);
        if let Some(entry) = self.entries_by_path.get(&key) {
            if entry.kind == ScanEntryKind::Attachment {
                return AttachmentResolutionState::Resolved {
                    relative_path: entry.relative_path.clone(),
                };
            }
            return AttachmentResolutionState::Unsupported;
        }

        match self.root.resolve_existing_relative(&target) {
            Ok(resolved) if classify_file(&resolved.relative_path) == ScanEntryKind::Attachment => {
                AttachmentResolutionState::Resolved {
                    relative_path: resolved.relative_path,
                }
            }
            Ok(_) => AttachmentResolutionState::Unsupported,
            Err(PathError::MissingPath(_)) => AttachmentResolutionState::Missing,
            Err(error) => map_path_error(error),
        }
    }
}

fn classify_url_target(target: &str) -> Option<AttachmentResolutionState> {
    let scheme = target_scheme(target)?;
    if matches!(scheme.to_ascii_lowercase().as_str(), "http" | "https") {
        return Some(AttachmentResolutionState::Remote);
    }
    Some(AttachmentResolutionState::Rejected(
        AttachmentRejectReason::UrlScheme,
    ))
}

fn is_markdown_attachment_candidate(link: &MarkdownLink) -> bool {
    if link.image {
        return true;
    }

    let target = link.target.trim();
    if let Some(scheme) = target_scheme(target) {
        return !matches!(scheme.to_ascii_lowercase().as_str(), "http" | "https");
    }

    let target = target.split('#').next().unwrap_or(target);
    classify_file(Path::new(target)) == ScanEntryKind::Attachment
}

fn target_scheme(target: &str) -> Option<&str> {
    let colon = target.find(':')?;
    let slash = target.find('/').unwrap_or(usize::MAX);
    if colon > slash {
        return None;
    }

    let scheme = &target[..colon];
    let mut chars = scheme.chars();
    let first = chars.next()?;
    if !first.is_ascii_alphabetic() {
        return None;
    }
    chars
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '+' | '-' | '.'))
        .then_some(scheme)
}

fn has_path_separator(target: &str) -> bool {
    target.contains('/')
}

fn map_path_error(error: PathError) -> AttachmentResolutionState {
    let reason = match error {
        PathError::ContainsNul => AttachmentRejectReason::ContainsNul,
        PathError::UrlScheme(_) => AttachmentRejectReason::UrlScheme,
        PathError::TildePrefix => AttachmentRejectReason::TildePrefix,
        PathError::AbsolutePath(_) => AttachmentRejectReason::AbsolutePath,
        PathError::OutsideVault(_) => AttachmentRejectReason::OutsideVault,
        PathError::SymlinkEscape { .. } | PathError::UnsupportedHardlink(_) => {
            AttachmentRejectReason::SymlinkEscape
        }
        PathError::RootNotDirectory(_) | PathError::MissingRoot(_) | PathError::MissingPath(_) => {
            AttachmentRejectReason::InvalidRoot
        }
    };
    AttachmentResolutionState::Rejected(reason)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapters::fs::scanner::scan_vault;
    use crate::core::markdown_parser::parse_markdown;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn resolves_compatibility_fixture_attachments() {
        let fixture_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("fixtures")
            .join("compatibility-vault");
        let root = VaultRoot::open(&fixture_root).expect("root");
        let scan = scan_vault(&root).expect("scan");
        let source =
            fs::read_to_string(fixture_root.join("Attachments.md")).expect("attachment note");
        let parsed = parse_markdown(&source);

        let references = resolve_attachment_references(
            &root,
            &scan,
            Path::new("Attachments.md"),
            &parsed,
            &AttachmentSettings::default(),
        );

        assert_eq!(
            states_by_target(&references),
            BTreeMap::from([
                (
                    "attachments/diagram.svg".to_string(),
                    AttachmentResolutionState::Resolved {
                        relative_path: PathBuf::from("attachments/diagram.svg")
                    }
                ),
                (
                    "attachments/missing.png".to_string(),
                    AttachmentResolutionState::Missing
                ),
                (
                    "attachments/spec.pdf".to_string(),
                    AttachmentResolutionState::Resolved {
                        relative_path: PathBuf::from("attachments/spec.pdf")
                    }
                ),
            ])
        );
    }

    #[test]
    fn classifies_adversarial_attachment_targets() {
        let fixture_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("fixtures")
            .join("adversarial-vault");
        let root = VaultRoot::open(&fixture_root).expect("root");
        let scan = scan_vault(&root).expect("scan");

        let traversal =
            fs::read_to_string(fixture_root.join("Traversal.md")).expect("traversal note");
        let parsed = parse_markdown(&traversal);
        let references = resolve_attachment_references(
            &root,
            &scan,
            Path::new("Traversal.md"),
            &parsed,
            &AttachmentSettings::default(),
        );
        assert!(references.iter().any(|reference| {
            reference.raw_target == "../../secret.png"
                && reference.state
                    == AttachmentResolutionState::Rejected(AttachmentRejectReason::OutsideVault)
        }));
        assert!(references.iter().any(|reference| {
            reference.raw_target == "file:///etc/passwd"
                && reference.state
                    == AttachmentResolutionState::Rejected(AttachmentRejectReason::UrlScheme)
        }));

        let urls = fs::read_to_string(fixture_root.join("UrlSchemes.md")).expect("url note");
        let parsed = parse_markdown(&urls);
        let references = resolve_attachment_references(
            &root,
            &scan,
            Path::new("UrlSchemes.md"),
            &parsed,
            &AttachmentSettings::default(),
        );
        assert!(references.iter().any(|reference| {
            reference.raw_target == "https://example.com/image.png"
                && reference.state == AttachmentResolutionState::Remote
        }));
    }

    #[test]
    fn reports_duplicate_basename_attachments() {
        let dir = tempdir().expect("tempdir");
        fs::create_dir_all(dir.path().join("a")).expect("a");
        fs::create_dir_all(dir.path().join("b")).expect("b");
        fs::write(dir.path().join("a").join("image.png"), "a").expect("image a");
        fs::write(dir.path().join("b").join("image.png"), "b").expect("image b");
        fs::write(dir.path().join("Note.md"), "![[image.png]]").expect("note");

        let root = VaultRoot::open(dir.path()).expect("root");
        let scan = scan_vault(&root).expect("scan");
        let parsed = parse_markdown("![[image.png]]");
        let references = resolve_attachment_references(
            &root,
            &scan,
            Path::new("Note.md"),
            &parsed,
            &AttachmentSettings::default(),
        );

        assert_eq!(
            references[0].state,
            AttachmentResolutionState::Duplicate {
                candidates: vec![PathBuf::from("a/image.png"), PathBuf::from("b/image.png")]
            }
        );
    }

    #[test]
    fn attachment_folder_setting_disambiguates_basenames() {
        let dir = tempdir().expect("tempdir");
        fs::create_dir_all(dir.path().join("attachments")).expect("attachments");
        fs::create_dir_all(dir.path().join("other")).expect("other");
        fs::write(dir.path().join("attachments").join("image.png"), "a").expect("image a");
        fs::write(dir.path().join("other").join("image.png"), "b").expect("image b");
        fs::write(dir.path().join("Note.md"), "![[image.png]]").expect("note");

        let root = VaultRoot::open(dir.path()).expect("root");
        let scan = scan_vault(&root).expect("scan");
        let parsed = parse_markdown("![[image.png]]");
        let references = resolve_attachment_references(
            &root,
            &scan,
            Path::new("Note.md"),
            &parsed,
            &AttachmentSettings {
                attachment_folder: Some(PathBuf::from("attachments")),
            },
        );

        assert_eq!(
            references[0].state,
            AttachmentResolutionState::Resolved {
                relative_path: PathBuf::from("attachments/image.png")
            }
        );
    }

    #[test]
    fn rejects_unsafe_local_attachment_paths() {
        let dir = tempdir().expect("tempdir");
        let root = VaultRoot::open(dir.path()).expect("root");
        let scan = scan_vault(&root).expect("scan");
        let parsed = parse_markdown("![[/tmp/secret.png]] ![[~/secret.png]] ![[bad\0path.png]]");
        let references = resolve_attachment_references(
            &root,
            &scan,
            Path::new("Note.md"),
            &parsed,
            &AttachmentSettings::default(),
        );

        assert_eq!(
            states_by_target(&references),
            BTreeMap::from([
                (
                    "/tmp/secret.png".to_string(),
                    AttachmentResolutionState::Rejected(AttachmentRejectReason::AbsolutePath)
                ),
                (
                    "~/secret.png".to_string(),
                    AttachmentResolutionState::Rejected(AttachmentRejectReason::TildePrefix)
                ),
                (
                    "bad\0path.png".to_string(),
                    AttachmentResolutionState::Rejected(AttachmentRejectReason::ContainsNul)
                ),
            ])
        );
    }

    #[test]
    fn marks_non_attachment_embeds_unsupported() {
        let dir = tempdir().expect("tempdir");
        fs::write(dir.path().join("Note.md"), "![[Other]]").expect("note");
        fs::write(dir.path().join("Other.md"), "# Other").expect("other");

        let root = VaultRoot::open(dir.path()).expect("root");
        let scan = scan_vault(&root).expect("scan");
        let parsed = parse_markdown("![[Other]]");
        let references = resolve_attachment_references(
            &root,
            &scan,
            Path::new("Note.md"),
            &parsed,
            &AttachmentSettings::default(),
        );

        assert_eq!(references[0].state, AttachmentResolutionState::Unsupported);
    }

    #[test]
    fn ignores_non_attachment_remote_markdown_links() {
        let dir = tempdir().expect("tempdir");
        fs::write(
            dir.path().join("Note.md"),
            "[Reference](https://example.com/reference)",
        )
        .expect("note");

        let root = VaultRoot::open(dir.path()).expect("root");
        let scan = scan_vault(&root).expect("scan");
        let parsed = parse_markdown("[Reference](https://example.com/reference)");
        let references = resolve_attachment_references(
            &root,
            &scan,
            Path::new("Note.md"),
            &parsed,
            &AttachmentSettings::default(),
        );

        assert!(references.is_empty());
    }

    fn states_by_target(
        references: &[AttachmentReference],
    ) -> BTreeMap<String, AttachmentResolutionState> {
        references
            .iter()
            .map(|reference| (reference.raw_target.clone(), reference.state.clone()))
            .collect()
    }
}
