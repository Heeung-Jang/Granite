pub const MAX_CODE_BLOCK_BYTES: usize = 256 * 1024;

pub const SYNTAX_TOKEN_KIND_KEYWORD: u32 = 1;
pub const SYNTAX_TOKEN_KIND_STRING: u32 = 2;
pub const SYNTAX_TOKEN_KIND_NUMBER: u32 = 3;
pub const SYNTAX_TOKEN_KIND_COMMENT: u32 = 4;
pub const SYNTAX_TOKEN_KIND_PROPERTY_KEY: u32 = 5;
pub const SYNTAX_TOKEN_KIND_OPERATOR: u32 = 6;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SyntaxLanguage {
    Yaml,
    Json,
    Java,
    Swift,
    Rust,
    Bash,
    Sql,
    JavaScript,
    TypeScript,
    Python,
    Html,
    Css,
    Markdown,
    Plain,
    Unsupported,
}

impl SyntaxLanguage {
    pub fn from_info_token(token: Option<&str>) -> Self {
        let Some(token) = token else {
            return Self::Plain;
        };
        match token.trim().to_ascii_lowercase().as_str() {
            "" => Self::Plain,
            "yaml" | "yml" => Self::Yaml,
            "json" => Self::Json,
            "java" => Self::Java,
            "swift" => Self::Swift,
            "rust" | "rs" => Self::Rust,
            "bash" | "sh" | "shell" => Self::Bash,
            "sql" => Self::Sql,
            "javascript" | "js" => Self::JavaScript,
            "typescript" | "ts" => Self::TypeScript,
            "python" | "py" => Self::Python,
            "html" => Self::Html,
            "css" => Self::Css,
            "markdown" | "md" => Self::Markdown,
            "text" | "txt" | "plain" => Self::Plain,
            _ => Self::Unsupported,
        }
    }

    pub fn is_tree_sitter_supported(self) -> bool {
        matches!(
            self,
            Self::Yaml
                | Self::Json
                | Self::Java
                | Self::Swift
                | Self::Rust
                | Self::Bash
                | Self::JavaScript
                | Self::TypeScript
                | Self::Python
                | Self::Html
                | Self::Css
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyntaxTokenKind {
    Keyword,
    String,
    Number,
    Comment,
    PropertyKey,
    Operator,
}

impl SyntaxTokenKind {
    pub fn abi_code(self) -> u32 {
        match self {
            Self::Keyword => SYNTAX_TOKEN_KIND_KEYWORD,
            Self::String => SYNTAX_TOKEN_KIND_STRING,
            Self::Number => SYNTAX_TOKEN_KIND_NUMBER,
            Self::Comment => SYNTAX_TOKEN_KIND_COMMENT,
            Self::PropertyKey => SYNTAX_TOKEN_KIND_PROPERTY_KEY,
            Self::Operator => SYNTAX_TOKEN_KIND_OPERATOR,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SyntaxHighlightToken {
    pub kind: SyntaxTokenKind,
    pub start_utf16: u32,
    pub length_utf16: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyntaxHighlightState {
    Complete,
    Plain,
    Unsupported,
    Skipped,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyntaxHighlightResult {
    pub state: SyntaxHighlightState,
    pub tokens: Vec<SyntaxHighlightToken>,
}

impl SyntaxHighlightResult {
    pub fn empty(state: SyntaxHighlightState) -> Self {
        Self {
            state,
            tokens: Vec::new(),
        }
    }
}
