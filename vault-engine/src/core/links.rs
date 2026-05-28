use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};

use crate::core::paths::lookup_key;

pub(crate) fn unresolved_target_key(target_text: &str) -> String {
    target_text.to_lowercase()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct NoteTarget<'a> {
    pub file_id: &'a str,
    pub relative_path: &'a Path,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum NoteTargetResolution<'a> {
    Resolved { file_id: &'a str },
    Missing,
    Ambiguous,
    Rejected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Candidate {
    Unique(usize),
    Ambiguous,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct IndexedNoteTarget {
    file_id: Box<str>,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct NoteTargetIndex {
    targets: Vec<IndexedNoteTarget>,
    exact_path: HashMap<String, Candidate>,
    basename: HashMap<String, Candidate>,
}

impl NoteTargetIndex {
    pub(crate) fn from_targets<'a>(targets: impl IntoIterator<Item = NoteTarget<'a>>) -> Self {
        let targets = targets.into_iter();
        let (lower, upper) = targets.size_hint();
        let capacity = upper.unwrap_or(lower);
        let mut index = Self {
            targets: Vec::with_capacity(capacity),
            exact_path: HashMap::with_capacity(capacity),
            basename: HashMap::with_capacity(capacity),
        };

        for target in targets {
            let Some(relative_path) = markdown_note_match_path(target.relative_path) else {
                continue;
            };
            let target_index = index.targets.len();
            index.targets.push(IndexedNoteTarget {
                file_id: target.file_id.into(),
            });
            insert_candidate(
                &mut index.exact_path,
                lookup_key(&relative_path),
                target_index,
            );
            if let Some(file_name) = relative_path.file_name() {
                insert_candidate(
                    &mut index.basename,
                    lookup_key(Path::new(file_name)),
                    target_index,
                );
            }
        }

        index
    }

    pub(crate) fn resolve_wiki_target<'a>(
        &'a self,
        source_relative_path: &Path,
        target_text: &str,
    ) -> NoteTargetResolution<'a> {
        self.resolve_note_target(source_relative_path, target_text, TargetKind::Wiki)
    }

    pub(crate) fn resolve_markdown_note_target<'a>(
        &'a self,
        source_relative_path: &Path,
        target_text: &str,
    ) -> NoteTargetResolution<'a> {
        self.resolve_note_target(source_relative_path, target_text, TargetKind::MarkdownLink)
    }

    fn resolve_note_target<'a>(
        &'a self,
        source_relative_path: &Path,
        target_text: &str,
        kind: TargetKind,
    ) -> NoteTargetResolution<'a> {
        let Some(target_path) = normalized_target_path(target_text, kind) else {
            return NoteTargetResolution::Rejected;
        };

        // Match Obsidian-style note lookup order: vault-root path, source-relative path, then unique basename.
        if let Some(resolution) = self.resolve_key(&lookup_key(&target_path)) {
            return resolution;
        }

        if let Some(source_relative_path) =
            source_relative_candidate(source_relative_path, &target_path)
        {
            if let Some(resolution) = self.resolve_key(&lookup_key(source_relative_path)) {
                return resolution;
            }
        }

        let Some(file_name) = target_path.file_name() else {
            return NoteTargetResolution::Missing;
        };
        self.resolve_basename_key(&lookup_key(Path::new(file_name)))
            .unwrap_or(NoteTargetResolution::Missing)
    }

    fn resolve_key<'a>(&'a self, key: &str) -> Option<NoteTargetResolution<'a>> {
        self.exact_path
            .get(key)
            .map(|candidate| self.resolve_candidate(*candidate))
    }

    fn resolve_basename_key<'a>(&'a self, key: &str) -> Option<NoteTargetResolution<'a>> {
        self.basename
            .get(key)
            .map(|candidate| self.resolve_candidate(*candidate))
    }

    fn resolve_candidate<'a>(&'a self, candidate: Candidate) -> NoteTargetResolution<'a> {
        match candidate {
            Candidate::Unique(index) => NoteTargetResolution::Resolved {
                file_id: &self.targets[index].file_id,
            },
            Candidate::Ambiguous => NoteTargetResolution::Ambiguous,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TargetKind {
    Wiki,
    MarkdownLink,
}

fn insert_candidate(candidates: &mut HashMap<String, Candidate>, key: String, index: usize) {
    candidates
        .entry(key)
        .and_modify(|candidate| *candidate = Candidate::Ambiguous)
        .or_insert(Candidate::Unique(index));
}

fn normalized_target_path(target_text: &str, kind: TargetKind) -> Option<PathBuf> {
    let target = match kind {
        TargetKind::Wiki => target_text.trim(),
        TargetKind::MarkdownLink => target_text
            .trim()
            .split_once('#')
            .map_or(target_text.trim(), |(path, _)| path.trim()),
    };
    if target.is_empty() || target.starts_with('#') || has_scheme_like_prefix(target) {
        return None;
    }
    normalized_match_path(Path::new(target))
}

fn markdown_note_match_path(path: &Path) -> Option<PathBuf> {
    let normalized = normalized_match_path(path)?;
    has_markdown_extension(path).then_some(normalized)
}

fn normalized_match_path(path: &Path) -> Option<PathBuf> {
    if path.is_absolute() {
        return None;
    }

    let without_extension = strip_markdown_extension(path);
    normalize_vault_relative_path(&without_extension)
}

fn source_relative_candidate(source_relative_path: &Path, target_path: &Path) -> Option<PathBuf> {
    let parent = source_relative_path.parent()?;
    let joined = parent.join(target_path);
    normalize_vault_relative_path(&joined)
}

fn normalize_vault_relative_path(path: &Path) -> Option<PathBuf> {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::Normal(value) => normalized.push(value),
            Component::ParentDir => {
                if !normalized.pop() {
                    return None;
                }
            }
            Component::RootDir | Component::Prefix(_) => return None,
        }
    }
    (!normalized.as_os_str().is_empty()).then_some(normalized)
}

fn strip_markdown_extension(path: &Path) -> PathBuf {
    if has_markdown_extension(path) {
        path.with_extension("")
    } else {
        path.to_path_buf()
    }
}

fn has_markdown_extension(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| {
            extension.eq_ignore_ascii_case("md") || extension.eq_ignore_ascii_case("markdown")
        })
}

fn has_scheme_like_prefix(target: &str) -> bool {
    let Some(colon) = target.find(':') else {
        return false;
    };
    let slash = target.find('/').unwrap_or(usize::MAX);
    if colon > slash {
        return false;
    }
    let scheme = &target[..colon];
    let mut chars = scheme.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    first.is_ascii_alphabetic()
        && chars.all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '+' | '-' | '.'))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn index<'a>(targets: impl IntoIterator<Item = (&'a str, &'a str)>) -> NoteTargetIndex {
        NoteTargetIndex::from_targets(targets.into_iter().map(|(file_id, relative_path)| {
            NoteTarget {
                file_id,
                relative_path: Path::new(relative_path),
            }
        }))
    }

    fn resolved_file_id<'a>(resolution: NoteTargetResolution<'a>) -> Option<&'a str> {
        match resolution {
            NoteTargetResolution::Resolved { file_id } => Some(file_id),
            _ => None,
        }
    }

    #[test]
    fn normalizes_target_text_and_markdown_suffixes() {
        let index = index([("target", "Folder/단순함을 추구.md")]);

        assert_eq!(
            resolved_file_id(
                index.resolve_wiki_target(Path::new("Home.md"), " Folder/단순함을 추구.md ")
            ),
            Some("target")
        );
        assert_eq!(
            resolved_file_id(
                index.resolve_wiki_target(Path::new("Home.md"), "folder/단순함을 추구")
            ),
            Some("target")
        );
        assert_eq!(
            resolved_file_id(index.resolve_wiki_target(Path::new("Home.md"), "   ")),
            None
        );
    }

    #[test]
    fn rejects_remote_and_fragment_only_targets() {
        let index = index([("target", "Target.md")]);

        assert_eq!(
            index.resolve_markdown_note_target(
                Path::new("Home.md"),
                "https://example.com/Target.md"
            ),
            NoteTargetResolution::Rejected
        );
        assert_eq!(
            index.resolve_markdown_note_target(Path::new("Home.md"), "mailto:test@example.com"),
            NoteTargetResolution::Rejected
        );
        assert_eq!(
            index.resolve_markdown_note_target(Path::new("Home.md"), "#Heading"),
            NoteTargetResolution::Rejected
        );
        assert_eq!(
            index.resolve_wiki_target(Path::new("Home.md"), "note:target"),
            NoteTargetResolution::Rejected
        );
    }

    #[test]
    fn resolves_exact_path_case_insensitively() {
        let index = index([("target", "Folder/Target.md")]);

        assert_eq!(
            resolved_file_id(index.resolve_wiki_target(Path::new("Home.md"), "folder/target.md")),
            Some("target")
        );
    }

    #[test]
    fn resolves_unique_basename_and_keeps_duplicates_ambiguous() {
        let unique = index([("target", "Folder/Target.md")]);
        assert_eq!(
            resolved_file_id(unique.resolve_wiki_target(Path::new("Home.md"), "Target")),
            Some("target")
        );

        let duplicate = index([("a", "A/Target.md"), ("b", "B/Target.md")]);
        assert_eq!(
            duplicate.resolve_wiki_target(Path::new("Home.md"), "Target"),
            NoteTargetResolution::Ambiguous
        );
    }

    #[test]
    fn resolves_current_note_relative_before_global_basename() {
        let index = index([
            ("local", "Notes/Target.md"),
            ("global", "Archive/Target.md"),
        ]);

        assert_eq!(
            resolved_file_id(index.resolve_wiki_target(Path::new("Notes/Home.md"), "Target")),
            Some("local")
        );
    }

    #[test]
    fn rejects_relative_candidates_that_escape_vault() {
        let index = index([("target", "Target.md")]);

        assert_eq!(
            index.resolve_wiki_target(Path::new("Home.md"), "../Target"),
            NoteTargetResolution::Rejected
        );
    }

    #[test]
    fn strips_markdown_link_fragment_before_resolution() {
        let index = index([("target", "Docs/Target.markdown")]);

        assert_eq!(
            resolved_file_id(index.resolve_markdown_note_target(
                Path::new("Home.md"),
                "Docs/Target.markdown#Heading"
            )),
            Some("target")
        );
    }

    #[test]
    fn builds_100k_targets_from_note_metadata_without_bodies_under_budget() {
        let targets = (0..100_000)
            .map(|index| (format!("id-{index}"), format!("Folder/Note-{index}.md")))
            .collect::<Vec<_>>();
        let started = std::time::Instant::now();
        let index =
            NoteTargetIndex::from_targets(targets.iter().map(|(file_id, relative_path)| {
                NoteTarget {
                    file_id,
                    relative_path: Path::new(relative_path),
                }
            }));
        let elapsed = started.elapsed();

        assert_eq!(index.targets.len(), 100_000);
        assert_eq!(
            resolved_file_id(index.resolve_wiki_target(Path::new("Home.md"), "Note-99999")),
            Some("id-99999")
        );
        assert!(
            elapsed <= std::time::Duration::from_millis(1_500),
            "100k resolver build exceeded budget: {elapsed:?}"
        );
    }
}
