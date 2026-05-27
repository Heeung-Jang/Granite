use std::collections::{BTreeMap, BTreeSet};

pub use crate::core::document::{
    FrontmatterBlock, Heading, MarkdownLink, ParseWarning, ParsedMarkdown, PropertyValue, WikiLink,
};

const MAX_FRONTMATTER_RAW_CHARS: usize = 65_536;
const MAX_PROPERTY_VALUE_CHARS: usize = 512;
const MAX_PROPERTY_LIST_ITEMS: usize = 128;

pub fn parse_markdown(source: &str) -> ParsedMarkdown {
    let frontmatter_parse = parse_frontmatter(source);
    let body = frontmatter_parse
        .body_start
        .and_then(|start| source.get(start..))
        .unwrap_or(source);
    let tags = collect_tags(body, &frontmatter_parse.properties);

    let mut parsed = ParsedMarkdown {
        headings: parse_headings(body),
        wikilinks: Vec::new(),
        embeds: Vec::new(),
        markdown_links: parse_markdown_links(body),
        tags,
        properties: frontmatter_parse.properties,
        frontmatter: frontmatter_parse.block,
        warnings: frontmatter_parse.warnings,
    };

    for link in parse_wikilinks(body) {
        if link.embed {
            parsed.embeds.push(link.link);
        } else {
            parsed.wikilinks.push(link.link);
        }
    }

    parsed
}

struct FrontmatterParse {
    block: Option<FrontmatterBlock>,
    properties: BTreeMap<String, PropertyValue>,
    warnings: Vec<ParseWarning>,
    body_start: Option<usize>,
}

fn parse_frontmatter(source: &str) -> FrontmatterParse {
    let bom_len = source
        .strip_prefix('\u{feff}')
        .map_or(0, |_| '\u{feff}'.len_utf8());
    let frontmatter_source = &source[bom_len..];
    let start_delimiter_len = if frontmatter_source.starts_with("---\n") {
        Some(4)
    } else if frontmatter_source.starts_with("---\r\n") {
        Some(5)
    } else if frontmatter_source.trim() == "---" {
        Some(3)
    } else {
        None
    };

    let Some(start_delimiter_len) = start_delimiter_len else {
        return FrontmatterParse {
            block: None,
            properties: BTreeMap::new(),
            warnings: Vec::new(),
            body_start: None,
        };
    };

    let raw_start = bom_len + start_delimiter_len;
    let mut cursor = raw_start;
    let mut end_line = None;
    let mut line_index = 0;
    while cursor < source.len() {
        let remainder = &source[cursor..];
        let (line, next_cursor) = if let Some(newline_offset) = remainder.find('\n') {
            let line_end = cursor + newline_offset;
            (&source[cursor..line_end], line_end + 1)
        } else {
            (remainder, source.len())
        };

        let normalized = line.trim_end_matches('\r');
        if normalized == "---" || normalized == "..." {
            end_line = Some((line_index + 2, cursor, next_cursor));
            break;
        }
        cursor = next_cursor;
        line_index += 1;
    }

    let Some((end_line, raw_end, body_start)) = end_line else {
        return FrontmatterParse {
            block: None,
            properties: BTreeMap::new(),
            warnings: vec![ParseWarning::MalformedFrontmatter(
                "frontmatter is not closed".to_string(),
            )],
            body_start: None,
        };
    };

    let mut warnings = Vec::new();
    let raw = truncate_frontmatter_raw(&source[raw_start..raw_end], &mut warnings);
    let properties = parse_frontmatter_properties(&raw, &mut warnings);

    FrontmatterParse {
        block: Some(FrontmatterBlock {
            raw,
            start_line: 1,
            end_line,
        }),
        properties,
        warnings,
        body_start: Some(body_start.min(source.len())),
    }
}

fn parse_frontmatter_properties(
    raw: &str,
    warnings: &mut Vec<ParseWarning>,
) -> BTreeMap<String, PropertyValue> {
    let mut properties = BTreeMap::new();
    let mut current_list_key: Option<String> = None;

    for line in raw.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }

        if let Some(item) = trimmed.strip_prefix("- ") {
            if let Some(key) = current_list_key.as_deref()
                && let Some(PropertyValue::List(values)) = properties.get_mut(key)
            {
                if values.len() >= MAX_PROPERTY_LIST_ITEMS {
                    push_once(warnings, ParseWarning::FrontmatterListTruncated);
                    continue;
                }
                let value = normalize_scalar(item, warnings);
                values.push(value);
            }
            continue;
        }

        let Some((key, raw_value)) = trimmed.split_once(':') else {
            current_list_key = None;
            warnings.push(ParseWarning::MalformedFrontmatter(
                "frontmatter line has no key separator".to_string(),
            ));
            continue;
        };

        let key = key.trim().to_string();
        let raw_value = raw_value.trim();
        if key.is_empty() {
            current_list_key = None;
            warnings.push(ParseWarning::MalformedFrontmatter(
                "frontmatter key is empty".to_string(),
            ));
            continue;
        }

        if raw_value.is_empty() {
            current_list_key = Some(key.clone());
            properties.insert(key, PropertyValue::List(Vec::new()));
            continue;
        }

        current_list_key = None;
        properties.insert(key, parse_property_value(raw_value, warnings));
    }

    properties
}

fn parse_property_value(raw_value: &str, warnings: &mut Vec<ParseWarning>) -> PropertyValue {
    if raw_value.eq_ignore_ascii_case("true") {
        return PropertyValue::Bool(true);
    }
    if raw_value.eq_ignore_ascii_case("false") {
        return PropertyValue::Bool(false);
    }

    if raw_value.starts_with('[') {
        if !raw_value.ends_with(']') {
            warnings.push(ParseWarning::MalformedFrontmatter(
                "inline list is not closed".to_string(),
            ));
            return PropertyValue::String(raw_value.to_string());
        }

        let values = raw_value
            .trim_matches(['[', ']'])
            .split(',')
            .filter_map(|value| {
                let value = normalize_scalar(value, warnings);
                (!value.is_empty()).then_some(value)
            })
            .take(MAX_PROPERTY_LIST_ITEMS)
            .collect();
        if raw_value.trim_matches(['[', ']']).split(',').count() > MAX_PROPERTY_LIST_ITEMS {
            push_once(warnings, ParseWarning::FrontmatterListTruncated);
        }
        return PropertyValue::List(values);
    }

    if raw_value.matches('"').count() % 2 == 1 || raw_value.matches('\'').count() % 2 == 1 {
        warnings.push(ParseWarning::MalformedFrontmatter(
            "quoted scalar is not closed".to_string(),
        ));
    }

    PropertyValue::String(normalize_scalar(raw_value, warnings))
}

fn normalize_scalar(value: &str, warnings: &mut Vec<ParseWarning>) -> String {
    let normalized = value
        .trim()
        .trim_matches('"')
        .trim_matches('\'')
        .trim()
        .to_string();
    truncate_property_value(normalized, warnings)
}

fn truncate_frontmatter_raw(raw: &str, warnings: &mut Vec<ParseWarning>) -> String {
    if raw.chars().count() <= MAX_FRONTMATTER_RAW_CHARS {
        return raw.to_string();
    }

    push_once(warnings, ParseWarning::FrontmatterRawTruncated);
    raw.chars().take(MAX_FRONTMATTER_RAW_CHARS).collect()
}

fn truncate_property_value(value: String, warnings: &mut Vec<ParseWarning>) -> String {
    if value.chars().count() <= MAX_PROPERTY_VALUE_CHARS {
        return value;
    }

    push_once(warnings, ParseWarning::FrontmatterValueTruncated);
    value.chars().take(MAX_PROPERTY_VALUE_CHARS).collect()
}

fn push_once(warnings: &mut Vec<ParseWarning>, warning: ParseWarning) {
    if !warnings.contains(&warning) {
        warnings.push(warning);
    }
}

fn collect_tags(body: &str, properties: &BTreeMap<String, PropertyValue>) -> Vec<String> {
    let mut tags = BTreeSet::new();

    if let Some(value) = properties.get("tags") {
        match value {
            PropertyValue::String(tag) => {
                if let Some(tag) = normalize_property_tag(tag) {
                    tags.insert(tag);
                }
            }
            PropertyValue::List(values) => {
                for tag in values {
                    if let Some(tag) = normalize_property_tag(tag) {
                        tags.insert(tag);
                    }
                }
            }
            PropertyValue::Bool(_) => {}
        }
    }

    for tag in parse_inline_tags(body) {
        tags.insert(tag);
    }

    tags.into_iter().filter(|tag| !tag.is_empty()).collect()
}

fn parse_inline_tags(source: &str) -> Vec<String> {
    source.lines().flat_map(parse_inline_tags_in_line).collect()
}

fn parse_inline_tags_in_line(line: &str) -> Vec<String> {
    let line = line_without_heading_marker(line);

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
        if is_valid_tag(&tag) {
            tags.push(tag);
        }
    }

    tags
}

fn line_without_heading_marker(line: &str) -> &str {
    let trimmed_start = line.trim_start();
    let level = trimmed_start.chars().take_while(|ch| *ch == '#').count();
    if !(1..=6).contains(&level) {
        return line;
    }

    let after_hashes = &trimmed_start[level..];
    if !after_hashes.chars().next().is_some_and(char::is_whitespace) {
        return line;
    }

    after_hashes.trim_start()
}

fn trim_hash(value: &str) -> String {
    value.trim().trim_start_matches('#').to_string()
}

fn normalize_property_tag(value: &str) -> Option<String> {
    let tag = trim_hash(value);
    is_valid_tag(&tag).then_some(tag)
}

fn is_valid_tag(tag: &str) -> bool {
    !tag.is_empty()
        && tag
            .chars()
            .all(|ch| ch.is_alphanumeric() || matches!(ch, '_' | '-' | '/'))
        && tag.chars().any(char::is_alphabetic)
}

fn parse_headings(source: &str) -> Vec<Heading> {
    source
        .lines()
        .filter_map(|line| {
            let trimmed = line.trim_start();
            let level = trimmed.chars().take_while(|ch| *ch == '#').count();
            if !(1..=6).contains(&level) {
                return None;
            }

            let after_hashes = &trimmed[level..];
            if !after_hashes.chars().next().is_some_and(char::is_whitespace) {
                return None;
            }
            let rest = after_hashes.trim_start();
            if rest.is_empty() {
                return None;
            }

            Some(Heading {
                level: level as u8,
                text: rest.trim_end_matches('#').trim_end().to_string(),
            })
        })
        .collect()
}

struct ParsedWikiLink {
    link: WikiLink,
    embed: bool,
}

fn parse_wikilinks(source: &str) -> Vec<ParsedWikiLink> {
    let mut links = Vec::new();
    let mut cursor = 0;

    while let Some(relative_start) = source[cursor..].find("[[") {
        let start = cursor + relative_start;
        let content_start = start + 2;
        let Some(relative_end) = source[content_start..].find("]]") else {
            break;
        };
        let end = content_start + relative_end;
        let raw_content = &source[content_start..end];
        let embed = start > 0 && source[..start].ends_with('!');

        if let Some(link) = parse_wikilink_content(raw_content) {
            links.push(ParsedWikiLink { link, embed });
        }

        cursor = end + 2;
    }

    links
}

fn parse_wikilink_content(raw: &str) -> Option<WikiLink> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }

    let (target_part, alias) = raw
        .split_once('|')
        .map(|(target, alias)| (target, Some(alias.trim().to_string())))
        .unwrap_or((raw, None));
    let (target, heading) = target_part
        .split_once('#')
        .map(|(target, heading)| (target.trim(), Some(heading.trim().to_string())))
        .unwrap_or((target_part.trim(), None));

    if target.is_empty() {
        return None;
    }

    Some(WikiLink {
        target: target.to_string(),
        heading: heading.filter(|value| !value.is_empty()),
        alias: alias.filter(|value| !value.is_empty()),
        raw: raw.to_string(),
    })
}

fn parse_markdown_links(source: &str) -> Vec<MarkdownLink> {
    let mut links = Vec::new();
    let bytes = source.as_bytes();
    let mut cursor = 0;

    while cursor < bytes.len() {
        let Some(relative_close) = source[cursor..].find("](") else {
            break;
        };
        let close = cursor + relative_close;
        let Some(open_relative) = source[..close].rfind('[') else {
            cursor = close + 2;
            continue;
        };
        let image = open_relative > 0 && source[..open_relative].ends_with('!');
        let text = &source[open_relative + 1..close];
        let target_start = close + 2;
        let Some(target_end) = find_markdown_target_end(source, target_start) else {
            break;
        };
        let target = source[target_start..target_end]
            .split_whitespace()
            .next()
            .unwrap_or("")
            .trim();

        if !target.is_empty() {
            links.push(MarkdownLink {
                text: text.to_string(),
                target: target.to_string(),
                image,
            });
        }

        cursor = target_end + 1;
    }

    links
}

fn find_markdown_target_end(source: &str, target_start: usize) -> Option<usize> {
    let mut depth = 0usize;

    for (offset, ch) in source[target_start..].char_indices() {
        match ch {
            '(' => depth += 1,
            ')' if depth == 0 => return Some(target_start + offset),
            ')' => depth -= 1,
            _ => {}
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use std::collections::{BTreeMap, BTreeSet};
    use std::fs;
    use std::path::{Component, Path, PathBuf};

    #[test]
    fn parses_common_markdown_link_shapes() {
        let parsed = parse_markdown(
            "# Title\n[[Note]] [[Folder/Note#Heading|Alias]] ![[Embed.png]] [Guide](Docs/Guide.md)",
        );

        assert_eq!(parsed.headings[0].text, "Title");
        assert_eq!(parsed.wikilinks[0].target, "Note");
        assert_eq!(parsed.wikilinks[1].target, "Folder/Note");
        assert_eq!(parsed.wikilinks[1].heading.as_deref(), Some("Heading"));
        assert_eq!(parsed.wikilinks[1].alias.as_deref(), Some("Alias"));
        assert_eq!(parsed.embeds[0].target, "Embed.png");
        assert_eq!(parsed.markdown_links[0].target, "Docs/Guide.md");
    }

    #[test]
    fn compatibility_fixture_matches_expected_link_records() {
        let fixture_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("fixtures")
            .join("compatibility-vault");
        let expected: Value = serde_json::from_str(
            &fs::read_to_string(fixture_root.join("expected-parser-records.json"))
                .expect("expected records"),
        )
        .expect("valid expected json");
        let index = FixtureIndex::load(&fixture_root);

        for file in expected["files"].as_array().expect("files array") {
            let path = file["path"].as_str().expect("fixture path");
            let source = fs::read_to_string(fixture_root.join(path)).expect("fixture markdown");
            let parsed = parse_markdown(&source);

            assert_eq!(
                json!(
                    parsed
                        .headings
                        .iter()
                        .map(|heading| heading.text.clone())
                        .collect::<Vec<_>>()
                ),
                file["headings"],
                "headings mismatch for {path}"
            );
            assert_eq!(
                json!(resolved_wikilinks(&index, &parsed.wikilinks)),
                file["wikilinks"],
                "wikilinks mismatch for {path}"
            );
            assert_eq!(
                json!(resolved_embeds(&index, &parsed.embeds)),
                file["embeds"],
                "embeds mismatch for {path}"
            );
            assert_eq!(
                json!(resolved_markdown_links(
                    &index,
                    Path::new(path),
                    &parsed.markdown_links
                )),
                file["markdown_links"],
                "markdown links mismatch for {path}"
            );
            assert_eq!(
                json!(sorted_tags(&parsed.tags)),
                json!(sorted_tags_from_json(&file["tags"])),
                "tags mismatch for {path}"
            );
            assert_eq!(
                properties_to_json(&parsed.properties),
                file["properties"],
                "properties mismatch for {path}"
            );
            assert_eq!(
                json!(unresolved_targets(
                    &index,
                    &parsed.wikilinks,
                    &parsed.embeds
                )),
                file["unresolved"],
                "unresolved mismatch for {path}"
            );
        }
    }

    #[test]
    fn parses_tag_and_frontmatter_shapes() {
        let parsed = parse_markdown(
            "\u{feff}---\r\naliases: [Primary, 'Secondary']\r\ntags:\r\n  - #한글/태그\r\n  - project/native\r\npublished: false\r\ncreated: 2026-05-19\r\n---\r\n# Heading #inline/tag\r\nBody #rust-lang #2026",
        );

        assert_eq!(
            sorted_tags(&parsed.tags),
            vec![
                "inline/tag".to_string(),
                "project/native".to_string(),
                "rust-lang".to_string(),
                "한글/태그".to_string(),
            ]
        );
        assert_eq!(
            parsed.properties.get("aliases"),
            Some(&PropertyValue::List(vec![
                "Primary".to_string(),
                "Secondary".to_string()
            ]))
        );
        assert_eq!(
            parsed.properties.get("published"),
            Some(&PropertyValue::Bool(false))
        );
        assert_eq!(
            parsed.properties.get("created"),
            Some(&PropertyValue::String("2026-05-19".to_string()))
        );
        let frontmatter = parsed.frontmatter.expect("frontmatter block");
        assert_eq!(frontmatter.start_line, 1);
        assert_eq!(frontmatter.end_line, 8);
        assert!(frontmatter.raw.contains("aliases:"));
    }

    #[test]
    fn malformed_frontmatter_warns_without_stopping_parse() {
        let fixture_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("fixtures")
            .join("adversarial-vault");
        let source = fs::read_to_string(fixture_root.join("MalformedFrontmatter.md"))
            .expect("malformed fixture");
        let parsed = parse_markdown(&source);

        assert!(
            parsed
                .warnings
                .iter()
                .any(|warning| matches!(warning, ParseWarning::MalformedFrontmatter(_)))
        );
        assert_eq!(parsed.headings[0].text, "Malformed Frontmatter");
        assert!(parsed.tags.is_empty());
    }

    #[test]
    fn parser_warnings_do_not_include_raw_frontmatter_values() {
        let parsed = parse_markdown("---\ntags: [broken\nsecret: \"private-token\n---\n# Note");
        let warning_text = format!("{:?}", parsed.warnings);

        assert!(
            parsed
                .warnings
                .iter()
                .any(|warning| matches!(warning, ParseWarning::MalformedFrontmatter(_)))
        );
        assert!(!warning_text.contains("private-token"));
        assert!(!warning_text.contains("[broken"));
    }

    #[test]
    fn oversized_frontmatter_values_are_bounded() {
        let fixture_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("fixtures")
            .join("adversarial-vault");
        let source =
            fs::read_to_string(fixture_root.join("OversizedAlias.md")).expect("oversized fixture");
        let parsed = parse_markdown(&source);

        assert!(
            parsed
                .warnings
                .contains(&ParseWarning::FrontmatterValueTruncated)
        );
        let Some(PropertyValue::List(aliases)) = parsed.properties.get("aliases") else {
            panic!("aliases list");
        };
        assert_eq!(aliases.len(), 1);
        assert!(aliases[0].chars().count() <= MAX_PROPERTY_VALUE_CHARS);
    }

    #[test]
    fn frontmatter_lists_are_bounded() {
        let tags = (0..(MAX_PROPERTY_LIST_ITEMS + 2))
            .map(|index| format!("  - tag{index}"))
            .collect::<Vec<_>>()
            .join("\n");
        let parsed = parse_markdown(&format!("---\ntags:\n{tags}\n---\n# Note"));

        assert!(
            parsed
                .warnings
                .contains(&ParseWarning::FrontmatterListTruncated)
        );
        let Some(PropertyValue::List(tags)) = parsed.properties.get("tags") else {
            panic!("tags list");
        };
        assert_eq!(tags.len(), MAX_PROPERTY_LIST_ITEMS);
    }

    #[test]
    fn frontmatter_raw_text_is_bounded() {
        let large_value = "a".repeat(MAX_FRONTMATTER_RAW_CHARS + 10);
        let parsed = parse_markdown(&format!("---\nnotes: {large_value}\n---\n# Note"));

        assert!(
            parsed
                .warnings
                .contains(&ParseWarning::FrontmatterRawTruncated)
        );
        let frontmatter = parsed.frontmatter.expect("frontmatter");
        assert!(frontmatter.raw.chars().count() <= MAX_FRONTMATTER_RAW_CHARS);
    }

    #[test]
    fn adversarial_html_and_plugin_syntax_remain_inert_parser_text() {
        let fixture_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("fixtures")
            .join("adversarial-vault");

        for fixture in ["RawHtmlScript.md", "PluginSyntax.md"] {
            let source = fs::read_to_string(fixture_root.join(fixture)).expect("fixture");
            let parsed = parse_markdown(&source);

            assert!(parsed.wikilinks.is_empty(), "{fixture} wikilinks");
            assert!(parsed.embeds.is_empty(), "{fixture} embeds");
            assert!(parsed.markdown_links.is_empty(), "{fixture} markdown links");
            assert!(parsed.warnings.is_empty(), "{fixture} warnings");
        }
    }

    #[test]
    fn unsafe_url_scheme_fixture_is_parsed_as_plain_link_targets() {
        let fixture_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("fixtures")
            .join("adversarial-vault");
        let source = fs::read_to_string(fixture_root.join("UrlSchemes.md")).expect("url fixture");
        let parsed = parse_markdown(&source);
        let targets = parsed
            .markdown_links
            .iter()
            .map(|link| link.target.clone())
            .collect::<Vec<_>>();

        assert_eq!(
            targets,
            vec![
                "javascript:alert(1)".to_string(),
                "data:text/html,<script>alert(1)</script>".to_string(),
                "obsidian://advanced-uri?vault=Codex".to_string(),
                "https://example.com/image.png".to_string(),
            ]
        );
    }

    #[derive(Debug)]
    struct FixtureIndex {
        note_targets: BTreeMap<String, Vec<FixtureNote>>,
        headings_by_path: BTreeMap<String, BTreeSet<String>>,
        files: BTreeSet<String>,
    }

    #[derive(Debug, Clone)]
    struct FixtureNote {
        path: String,
    }

    impl FixtureIndex {
        fn load(root: &Path) -> Self {
            let mut index = Self {
                note_targets: BTreeMap::new(),
                headings_by_path: BTreeMap::new(),
                files: BTreeSet::new(),
            };
            index.visit(root, root);
            index
        }

        fn visit(&mut self, root: &Path, directory: &Path) {
            for entry in fs::read_dir(directory).expect("read fixture directory") {
                let path = entry.expect("fixture entry").path();
                if path.is_dir() {
                    if path.file_name().and_then(|value| value.to_str()) == Some(".obsidian") {
                        continue;
                    }
                    self.visit(root, &path);
                    continue;
                }

                let relative = path
                    .strip_prefix(root)
                    .expect("fixture relative path")
                    .to_string_lossy()
                    .to_string();
                self.files.insert(relative.clone());

                if path.extension().and_then(|value| value.to_str()) != Some("md") {
                    continue;
                }

                let source = fs::read_to_string(&path).expect("fixture note");
                let parsed = parse_markdown(&source);
                let note = FixtureNote {
                    path: relative.clone(),
                };
                for key in note_keys(&relative) {
                    self.note_targets.entry(key).or_default().push(note.clone());
                }
                self.headings_by_path.insert(
                    relative,
                    parsed
                        .headings
                        .into_iter()
                        .map(|heading| heading.text.to_lowercase())
                        .collect(),
                );
            }
        }

        fn resolve_wikilink(&self, link: &WikiLink) -> Value {
            let key = target_key(&link.target);
            let candidates = self.note_targets.get(&key).cloned().unwrap_or_default();
            if candidates.len() > 1 {
                return json!("ambiguous");
            }

            let Some(candidate) = candidates.first() else {
                if self.files.contains(&link.target) {
                    return json!(true);
                }
                return json!(false);
            };

            if let Some(heading) = &link.heading {
                let headings = self
                    .headings_by_path
                    .get(&candidate.path)
                    .expect("candidate headings");
                return json!(headings.contains(&heading.to_lowercase()));
            }

            json!(true)
        }

        fn resolve_markdown_link(&self, note_path: &Path, target: &str) -> Value {
            if is_external_target(target) {
                return json!("external");
            }

            let path = normalize_markdown_target(note_path, target);
            json!(path.as_ref().is_some_and(|path| self.files.contains(path)))
        }
    }

    fn note_keys(relative: &str) -> Vec<String> {
        let path = Path::new(relative);
        let without_extension = path.with_extension("");
        let mut keys = vec![target_key(&without_extension.to_string_lossy())];
        if let Some(stem) = path.file_stem().and_then(|value| value.to_str()) {
            let basename_key = target_key(stem);
            if !keys.contains(&basename_key) {
                keys.push(basename_key);
            }
        }
        keys
    }

    fn target_key(target: &str) -> String {
        target.trim().trim_end_matches(".md").to_lowercase()
    }

    fn resolved_wikilinks(index: &FixtureIndex, links: &[WikiLink]) -> Vec<Value> {
        links
            .iter()
            .map(|link| {
                let mut value = json!({
                    "target": link.target,
                    "resolved": index.resolve_wikilink(link)
                });
                if let Some(heading) = &link.heading {
                    value["heading"] = json!(heading);
                }
                if let Some(alias) = &link.alias {
                    value["alias"] = json!(alias);
                }
                value
            })
            .collect()
    }

    fn resolved_embeds(index: &FixtureIndex, links: &[WikiLink]) -> Vec<Value> {
        links
            .iter()
            .map(|link| {
                json!({
                    "target": link.target,
                    "resolved": index.resolve_wikilink(link)
                })
            })
            .collect()
    }

    fn resolved_markdown_links(
        index: &FixtureIndex,
        note_path: &Path,
        links: &[MarkdownLink],
    ) -> Vec<Value> {
        links
            .iter()
            .filter(|link| !link.image)
            .map(|link| {
                json!({
                    "target": link.target,
                    "resolved": index.resolve_markdown_link(note_path, &link.target)
                })
            })
            .collect()
    }

    fn unresolved_targets(
        index: &FixtureIndex,
        wikilinks: &[WikiLink],
        embeds: &[WikiLink],
    ) -> Vec<String> {
        wikilinks
            .iter()
            .chain(embeds)
            .filter(|link| index.resolve_wikilink(link) == json!(false))
            .map(|link| link.target.clone())
            .collect()
    }

    fn sorted_tags(tags: &[String]) -> Vec<String> {
        let mut tags = tags.to_vec();
        tags.sort();
        tags
    }

    fn sorted_tags_from_json(value: &Value) -> Vec<String> {
        let mut tags = value
            .as_array()
            .expect("tags array")
            .iter()
            .map(|tag| tag.as_str().expect("tag string").to_string())
            .collect::<Vec<_>>();
        tags.sort();
        tags
    }

    fn properties_to_json(properties: &BTreeMap<String, PropertyValue>) -> Value {
        let values = properties
            .iter()
            .map(|(key, value)| (key.clone(), property_value_to_json(value)))
            .collect::<BTreeMap<_, _>>();
        json!(values)
    }

    fn property_value_to_json(value: &PropertyValue) -> Value {
        match value {
            PropertyValue::String(value) => json!(value),
            PropertyValue::Bool(value) => json!(value),
            PropertyValue::List(values) => json!(values),
        }
    }

    fn normalize_markdown_target(note_path: &Path, target: &str) -> Option<String> {
        let target = target.split('#').next().unwrap_or(target);
        let mut path = note_path
            .parent()
            .unwrap_or_else(|| Path::new(""))
            .join(target);
        let mut normalized = PathBuf::new();
        for component in path.components() {
            match component {
                Component::CurDir => {}
                Component::ParentDir => {
                    normalized.pop();
                }
                Component::Normal(value) => normalized.push(value),
                Component::RootDir | Component::Prefix(_) => return None,
            }
        }
        path = normalized;
        Some(path.to_string_lossy().to_string())
    }

    fn is_external_target(target: &str) -> bool {
        let lower = target.to_ascii_lowercase();
        lower.starts_with("http://") || lower.starts_with("https://")
    }
}
