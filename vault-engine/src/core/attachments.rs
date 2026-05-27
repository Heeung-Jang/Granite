use std::path::PathBuf;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AttachmentSettings {
    pub attachment_folder: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttachmentReference {
    pub source: AttachmentReferenceSource,
    pub raw_target: String,
    pub state: AttachmentResolutionState,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AttachmentReferenceSource {
    WikiEmbed,
    MarkdownImage,
    MarkdownLink,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AttachmentResolutionState {
    Resolved { relative_path: PathBuf },
    Missing,
    Duplicate { candidates: Vec<PathBuf> },
    Remote,
    Rejected(AttachmentRejectReason),
    Unsupported,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AttachmentRejectReason {
    ContainsNul,
    UrlScheme,
    TildePrefix,
    AbsolutePath,
    OutsideVault,
    SymlinkEscape,
    InvalidRoot,
}
