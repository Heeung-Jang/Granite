use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::adapters::sqlite::metadata_store::{MetadataStoreError, MetadataStoreResult};
use crate::core::attachments::{
    AttachmentReferenceSource, AttachmentRejectReason, AttachmentResolutionState,
};
use crate::core::metadata::{FileIndexStatus, IndexPropertyValue, TagSource};
use crate::scanner::ScanEntryKind;

pub(crate) fn property_value_to_storage(
    value: &IndexPropertyValue,
) -> MetadataStoreResult<(&'static str, String)> {
    let stored = match value {
        IndexPropertyValue::String(value) => ("string", serde_json::to_string(value)),
        IndexPropertyValue::Bool(value) => ("bool", serde_json::to_string(value)),
        IndexPropertyValue::List(values) => ("list", serde_json::to_string(values)),
    };
    Ok((
        stored.0,
        stored
            .1
            .map_err(|_| MetadataStoreError::InvalidStoredValue("property"))?,
    ))
}

pub(crate) fn property_value_from_storage(
    kind: &str,
    json: &str,
) -> MetadataStoreResult<IndexPropertyValue> {
    match kind {
        "string" => serde_json::from_str(json)
            .map(IndexPropertyValue::String)
            .map_err(|_| MetadataStoreError::InvalidStoredValue("property")),
        "bool" => serde_json::from_str(json)
            .map(IndexPropertyValue::Bool)
            .map_err(|_| MetadataStoreError::InvalidStoredValue("property")),
        "list" => serde_json::from_str(json)
            .map(IndexPropertyValue::List)
            .map_err(|_| MetadataStoreError::InvalidStoredValue("property")),
        _ => Err(MetadataStoreError::InvalidStoredValue("property")),
    }
}

pub(crate) fn attachment_state_to_storage(
    state: &AttachmentResolutionState,
) -> MetadataStoreResult<(&'static str, Option<String>)> {
    match state {
        AttachmentResolutionState::Resolved { relative_path } => {
            Ok(("resolved", Some(path_to_string(relative_path))))
        }
        AttachmentResolutionState::Missing => Ok(("missing", None)),
        AttachmentResolutionState::Duplicate { candidates } => Ok((
            "duplicate",
            Some(
                serde_json::to_string(
                    &candidates
                        .iter()
                        .map(|path| path_to_string(path))
                        .collect::<Vec<_>>(),
                )
                .map_err(|_| MetadataStoreError::InvalidStoredValue("attachment"))?,
            ),
        )),
        AttachmentResolutionState::Remote => Ok(("remote", None)),
        AttachmentResolutionState::Rejected(reason) => {
            Ok(("rejected", Some(format!("{reason:?}"))))
        }
        AttachmentResolutionState::Unsupported => Ok(("unsupported", None)),
    }
}

pub(crate) fn attachment_state_from_storage(
    state: &str,
    detail: Option<&str>,
) -> MetadataStoreResult<AttachmentResolutionState> {
    match state {
        "resolved" => Ok(AttachmentResolutionState::Resolved {
            relative_path: PathBuf::from(required_detail(detail, "attachment")?),
        }),
        "missing" => Ok(AttachmentResolutionState::Missing),
        "duplicate" => {
            let values: Vec<String> = serde_json::from_str(required_detail(detail, "attachment")?)
                .map_err(|_| MetadataStoreError::InvalidStoredValue("attachment"))?;
            Ok(AttachmentResolutionState::Duplicate {
                candidates: values.into_iter().map(PathBuf::from).collect(),
            })
        }
        "remote" => Ok(AttachmentResolutionState::Remote),
        "rejected" => Ok(AttachmentResolutionState::Rejected(
            reject_reason_from_str(required_detail(detail, "attachment")?)
                .ok_or(MetadataStoreError::InvalidStoredValue("attachment"))?,
        )),
        "unsupported" => Ok(AttachmentResolutionState::Unsupported),
        _ => Err(MetadataStoreError::InvalidStoredValue("attachment")),
    }
}

fn required_detail<'a>(
    detail: Option<&'a str>,
    field: &'static str,
) -> MetadataStoreResult<&'a str> {
    detail.ok_or(MetadataStoreError::InvalidStoredValue(field))
}

pub(crate) fn path_to_string(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

pub(crate) fn optional_path(value: Option<String>) -> Option<PathBuf> {
    value.map(PathBuf::from)
}

pub(crate) fn bool_to_int(value: bool) -> i64 {
    if value { 1 } else { 0 }
}

pub(crate) fn int_to_bool(value: i64) -> bool {
    value != 0
}

pub(crate) fn system_time_to_unix_ms(time: Option<SystemTime>) -> Option<i64> {
    time.and_then(|time| {
        time.duration_since(UNIX_EPOCH)
            .ok()
            .map(|duration| duration.as_millis() as i64)
    })
}

pub(crate) fn unix_ms_to_system_time(ms: Option<i64>) -> Option<SystemTime> {
    ms.map(|ms| UNIX_EPOCH + Duration::from_millis(ms as u64))
}

pub(crate) fn scan_kind_to_str(kind: ScanEntryKind) -> &'static str {
    match kind {
        ScanEntryKind::Markdown => "markdown",
        ScanEntryKind::Attachment => "attachment",
        ScanEntryKind::Other => "other",
    }
}

pub(crate) fn scan_kind_from_str(kind: &str) -> Result<ScanEntryKind, ()> {
    match kind {
        "markdown" => Ok(ScanEntryKind::Markdown),
        "attachment" => Ok(ScanEntryKind::Attachment),
        "other" => Ok(ScanEntryKind::Other),
        _ => Err(()),
    }
}

pub(crate) fn file_status_to_str(status: FileIndexStatus) -> &'static str {
    match status {
        FileIndexStatus::SeenMetadata => "seen_metadata",
        FileIndexStatus::Parsed => "parsed",
        FileIndexStatus::SearchIndexed => "search_indexed",
        FileIndexStatus::Tombstoned => "tombstoned",
        FileIndexStatus::Error => "error",
    }
}

pub(crate) fn file_status_from_str(status: &str) -> Result<FileIndexStatus, ()> {
    match status {
        "seen_metadata" => Ok(FileIndexStatus::SeenMetadata),
        "parsed" => Ok(FileIndexStatus::Parsed),
        "search_indexed" => Ok(FileIndexStatus::SearchIndexed),
        "tombstoned" => Ok(FileIndexStatus::Tombstoned),
        "error" => Ok(FileIndexStatus::Error),
        _ => Err(()),
    }
}

pub(crate) fn tag_source_to_str(source: TagSource) -> &'static str {
    match source {
        TagSource::Inline => "inline",
        TagSource::Frontmatter => "frontmatter",
    }
}

pub(crate) fn tag_source_from_str(source: &str) -> Result<TagSource, ()> {
    match source {
        "inline" => Ok(TagSource::Inline),
        "frontmatter" => Ok(TagSource::Frontmatter),
        _ => Err(()),
    }
}

pub(crate) fn attachment_source_to_str(source: AttachmentReferenceSource) -> &'static str {
    match source {
        AttachmentReferenceSource::WikiEmbed => "wiki_embed",
        AttachmentReferenceSource::MarkdownImage => "markdown_image",
        AttachmentReferenceSource::MarkdownLink => "markdown_link",
    }
}

pub(crate) fn attachment_source_from_str(source: &str) -> Result<AttachmentReferenceSource, ()> {
    match source {
        "wiki_embed" => Ok(AttachmentReferenceSource::WikiEmbed),
        "markdown_image" => Ok(AttachmentReferenceSource::MarkdownImage),
        "markdown_link" => Ok(AttachmentReferenceSource::MarkdownLink),
        _ => Err(()),
    }
}

fn reject_reason_from_str(reason: &str) -> Option<AttachmentRejectReason> {
    match reason {
        "ContainsNul" => Some(AttachmentRejectReason::ContainsNul),
        "UrlScheme" => Some(AttachmentRejectReason::UrlScheme),
        "TildePrefix" => Some(AttachmentRejectReason::TildePrefix),
        "AbsolutePath" => Some(AttachmentRejectReason::AbsolutePath),
        "OutsideVault" => Some(AttachmentRejectReason::OutsideVault),
        "SymlinkEscape" => Some(AttachmentRejectReason::SymlinkEscape),
        "InvalidRoot" => Some(AttachmentRejectReason::InvalidRoot),
        _ => None,
    }
}
