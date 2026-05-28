use std::path::Path;

use crate::adapters::sqlite::FileLookupProjection;
use crate::core::document::{MarkdownLink, PropertyValue, WikiLink};
use crate::core::markdown_parser::parse_markdown;
use crate::core::scan::{ScanEntryKind, classify_file};

use super::read_types::{
    LivePreviewMetadataItem, LivePreviewMetadataItemKind, LivePreviewMetadataSource,
    LivePreviewMetadataState, MAX_PAGE_LIMIT, ReadApiError, ReadApiResult, ReadPage, ReadState,
};
use super::read_vault::VaultReadApi;

impl VaultReadApi {
    pub fn live_preview_metadata(
        &self,
        request_id: u64,
        relative_path: &str,
        contents: &str,
    ) -> ReadApiResult<ReadPage<LivePreviewMetadataItem>> {
        if relative_path.trim().is_empty() {
            return Err(ReadApiError::InvalidInput("relative_path"));
        }

        let parsed = parse_markdown(contents);
        let mut items = Vec::new();

        for (key, value) in &parsed.properties {
            items.push(LivePreviewMetadataItem {
                kind: LivePreviewMetadataItemKind::Property,
                key: key.clone(),
                value: display_property_value(value),
                resolved_file_id: None,
                resolved_relative_path: None,
                heading: None,
                alias: None,
                state: LivePreviewMetadataState::None,
                source: LivePreviewMetadataSource::None,
            });
        }

        for tag in &parsed.tags {
            items.push(LivePreviewMetadataItem {
                kind: LivePreviewMetadataItemKind::Tag,
                key: "tag".to_string(),
                value: tag.clone(),
                resolved_file_id: None,
                resolved_relative_path: None,
                heading: None,
                alias: None,
                state: LivePreviewMetadataState::None,
                source: LivePreviewMetadataSource::Inline,
            });
        }

        for link in &parsed.wikilinks {
            items.push(self.live_wiki_link_item(link)?);
        }

        for embed in &parsed.embeds {
            items.push(self.live_wiki_embed_item(embed)?);
        }

        for link in &parsed.markdown_links {
            items.push(self.live_markdown_link_item(relative_path, link)?);
        }

        let has_next = items.len() > MAX_PAGE_LIMIT;
        if has_next {
            items.truncate(MAX_PAGE_LIMIT);
        }

        Ok(ReadPage {
            request_id,
            generation: self.generation,
            items,
            next_offset: has_next.then_some(MAX_PAGE_LIMIT),
            state: if has_next {
                ReadState::Partial
            } else {
                ReadState::Complete
            },
        })
    }

    fn live_wiki_link_item(&self, link: &WikiLink) -> ReadApiResult<LivePreviewMetadataItem> {
        let resolved = self.resolve_wiki_target(&link.target)?;
        Ok(link_metadata_item(
            LivePreviewMetadataItemKind::Link,
            "wikilink",
            &link.target,
            resolved,
            link.heading.clone(),
            link.alias.clone(),
            LivePreviewMetadataSource::WikiLink,
        ))
    }

    fn live_wiki_embed_item(&self, embed: &WikiLink) -> ReadApiResult<LivePreviewMetadataItem> {
        let resolved = self.resolve_wiki_target(&embed.target)?;
        Ok(link_metadata_item(
            LivePreviewMetadataItemKind::Attachment,
            "embed",
            &embed.target,
            resolved,
            embed.heading.clone(),
            embed.alias.clone(),
            LivePreviewMetadataSource::WikiEmbed,
        ))
    }

    fn live_markdown_link_item(
        &self,
        relative_path: &str,
        link: &MarkdownLink,
    ) -> ReadApiResult<LivePreviewMetadataItem> {
        let target = link.target.split('#').next().unwrap_or(&link.target);
        let is_attachment =
            link.image || classify_file(Path::new(target)) == ScanEntryKind::Attachment;
        let resolved = self.resolve_markdown_target(relative_path, target)?;
        Ok(link_metadata_item(
            if is_attachment {
                LivePreviewMetadataItemKind::Attachment
            } else {
                LivePreviewMetadataItemKind::Link
            },
            if link.image { "image" } else { "markdown_link" },
            &link.target,
            resolved,
            None,
            Some(link.text.clone()),
            if link.image {
                LivePreviewMetadataSource::MarkdownImage
            } else {
                LivePreviewMetadataSource::MarkdownLink
            },
        ))
    }

    fn resolve_wiki_target(&self, target: &str) -> ReadApiResult<LivePreviewTargetResolution> {
        if is_remote_target(target) {
            return Ok(LivePreviewTargetResolution::remote());
        }
        if is_rejected_target(target) {
            return Ok(LivePreviewTargetResolution::rejected());
        }
        self.resolve_target_candidates(link_target_candidates(target))
    }

    fn resolve_markdown_target(
        &self,
        relative_path: &str,
        target: &str,
    ) -> ReadApiResult<LivePreviewTargetResolution> {
        if is_remote_target(target) {
            return Ok(LivePreviewTargetResolution::remote());
        }
        if is_rejected_target(target) {
            return Ok(LivePreviewTargetResolution::rejected());
        }

        let target_path = Path::new(relative_path)
            .parent()
            .unwrap_or_else(|| Path::new(""))
            .join(target);
        self.resolve_target_candidates(path_target_candidates(&target_path))
    }

    fn resolve_target_candidates(
        &self,
        candidates: Vec<String>,
    ) -> ReadApiResult<LivePreviewTargetResolution> {
        if candidates.is_empty() {
            return Ok(LivePreviewTargetResolution::missing());
        }
        for candidate in candidates {
            if let Some(file) = self.metadata.lookup_file(&candidate)? {
                return Ok(LivePreviewTargetResolution::resolved(file));
            }
        }
        Ok(LivePreviewTargetResolution::missing())
    }
}

struct LivePreviewTargetResolution {
    file: Option<FileLookupProjection>,
    state: LivePreviewMetadataState,
}

impl LivePreviewTargetResolution {
    fn resolved(file: FileLookupProjection) -> Self {
        Self {
            file: Some(file),
            state: LivePreviewMetadataState::Resolved,
        }
    }

    fn missing() -> Self {
        Self {
            file: None,
            state: LivePreviewMetadataState::Missing,
        }
    }

    fn remote() -> Self {
        Self {
            file: None,
            state: LivePreviewMetadataState::Remote,
        }
    }

    fn rejected() -> Self {
        Self {
            file: None,
            state: LivePreviewMetadataState::Rejected,
        }
    }
}

fn display_property_value(value: &PropertyValue) -> String {
    match value {
        PropertyValue::String(value) => value.clone(),
        PropertyValue::Bool(value) => value.to_string(),
        PropertyValue::List(values) => values.join(", "),
    }
}

fn link_metadata_item(
    kind: LivePreviewMetadataItemKind,
    key: &str,
    value: &str,
    resolved: LivePreviewTargetResolution,
    heading: Option<String>,
    alias: Option<String>,
    source: LivePreviewMetadataSource,
) -> LivePreviewMetadataItem {
    LivePreviewMetadataItem {
        kind,
        key: key.to_string(),
        value: value.to_string(),
        resolved_file_id: resolved.file.as_ref().map(|file| file.file_id.clone()),
        resolved_relative_path: resolved.file.map(|file| file.display_path),
        heading,
        alias,
        state: resolved.state,
        source,
    }
}

fn link_target_candidates(target: &str) -> Vec<String> {
    let target = target.trim();
    if target.is_empty() {
        return Vec::new();
    }
    path_target_candidates(Path::new(target))
}

fn path_target_candidates(path: &Path) -> Vec<String> {
    let mut candidates = Vec::new();
    let value = path.to_string_lossy().trim().to_string();
    if value.is_empty() {
        return candidates;
    }
    candidates.push(value.clone());
    if path.extension().is_none() {
        candidates.push(format!("{value}.md"));
    }
    candidates
}

fn is_remote_target(target: &str) -> bool {
    target_scheme(target).is_some_and(|scheme| {
        scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https")
    })
}

fn is_rejected_target(target: &str) -> bool {
    target_scheme(target).is_some() && !is_remote_target(target)
}

fn target_scheme(target: &str) -> Option<&str> {
    let colon = target.find(':')?;
    let slash = target.find('/').unwrap_or(usize::MAX);
    (colon < slash).then(|| &target[..colon])
}
