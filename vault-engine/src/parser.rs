#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedMarkdown {
    pub headings: Vec<Heading>,
    pub wikilinks: Vec<WikiLink>,
    pub embeds: Vec<WikiLink>,
    pub markdown_links: Vec<MarkdownLink>,
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

pub fn parse_markdown(source: &str) -> ParsedMarkdown {
    let mut parsed = ParsedMarkdown {
        headings: parse_headings(source),
        wikilinks: Vec::new(),
        embeds: Vec::new(),
        markdown_links: parse_markdown_links(source),
    };

    for link in parse_wikilinks(source) {
        if link.embed {
            parsed.embeds.push(link.link);
        } else {
            parsed.wikilinks.push(link.link);
        }
    }

    parsed
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
        let Some(relative_target_end) = source[target_start..].find(')') else {
            break;
        };
        let target_end = target_start + relative_target_end;
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
