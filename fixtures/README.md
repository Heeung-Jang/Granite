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

## Adversarial Vault

`adversarial-vault` treats vault contents as untrusted input.

The authoritative expected safety classifications are in `adversarial-vault/expected-safety-records.json`.

Covered behavior:

- Path traversal, absolute paths, unsafe URL schemes, and remote attachments.
- Malformed YAML/frontmatter and oversized aliases.
- Raw HTML/script, Dataview, Templater, plugin JavaScript, and CSS snippets.
- Recursive embeds and symlink loops.
