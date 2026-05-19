# Fixtures

## Compatibility Vault

`compatibility-vault` locks down expected Obsidian-compatible parser behavior before parser code exists.

The authoritative expected records are in `compatibility-vault/expected-parser-records.json`.

Covered behavior:

- Wikilinks, heading links, aliases, duplicate basenames, and missing links.
- Markdown links and external links.
- Embeds and attachment references.
- Inline tags, YAML tags, and frontmatter properties.
- Excluded `.obsidian` paths.

