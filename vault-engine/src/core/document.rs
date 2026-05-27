use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedMarkdown {
    pub headings: Vec<Heading>,
    pub wikilinks: Vec<WikiLink>,
    pub embeds: Vec<WikiLink>,
    pub markdown_links: Vec<MarkdownLink>,
    pub tags: Vec<String>,
    pub properties: BTreeMap<String, PropertyValue>,
    pub frontmatter: Option<FrontmatterBlock>,
    pub warnings: Vec<ParseWarning>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Heading {
    pub level: u8,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WikiLink {
    pub target: String,
    pub heading: Option<String>,
    pub alias: Option<String>,
    pub raw: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarkdownLink {
    pub text: String,
    pub target: String,
    pub image: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FrontmatterBlock {
    pub raw: String,
    pub start_line: usize,
    pub end_line: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PropertyValue {
    String(String),
    Bool(bool),
    List(Vec<String>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseWarning {
    MalformedFrontmatter(String),
    FrontmatterRawTruncated,
    FrontmatterValueTruncated,
    FrontmatterListTruncated,
}
