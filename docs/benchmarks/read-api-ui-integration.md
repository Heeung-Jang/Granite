# Read API UI Integration Benchmarks

This document defines the smoke and real-vault targets for replacing Swift filesystem read loaders with the Rust read API.

## Scope

Measured surfaces:

- File tree first page.
- Search first page.
- Inspector visible tab, starting with backlinks.
- Properties panel.
- Local graph 1-hop.
- Live Preview link and embed metadata resolution.

The benchmark assumes an indexed vault. Cold indexing and rebuild throughput are tracked separately.

## Fixture Budgets

Synthetic fixtures are privacy-safe and should run in CI or local smoke checks.

| Surface | Budget |
| --- | ---: |
| Placeholder or partial state | `<= 200ms` |
| File tree first page | `<= 300ms` |
| Search first page | `<= 500ms` |
| Inspector default backlinks | `<= 500ms` |
| Properties panel | `<= 300ms` |
| Local graph 1-hop | `<= 500ms` |

## Real Vault Targets

Use `/Users/heeung/Documents/Codex Vault` as a read-only private benchmark corpus. Artifacts must be redacted and must not include raw note text, note paths, snippets, frontmatter values, tag names, or screenshots from private content.

| Surface | Target |
| --- | ---: |
| Placeholder or partial state | `<= 200ms` |
| File tree first page | `p95 <= 1s` |
| Search first page | `p95 <= 1s`, `p99 <= 3s` |
| Inspector visible tab | `p95 <= 1s`, `p99 <= 3s` |
| Properties panel | `p95 <= 1s` |
| Local graph 1-hop | `p95 <= 1s`, `p99 <= 3s` |

## Planned Commands

Rust read benchmark:

```bash
cargo run --manifest-path bench/vault-profiler/Cargo.toml -- read-api-benchmark \
  --metadata-path "<app-support-index>/data/metadata.sqlite" \
  --tantivy-path "<app-support-index>/data/tantivy" \
  --vault "/Users/heeung/Documents/Codex Vault" \
  --samples 100 \
  --output docs/benchmarks/artifacts/read-api-real-2026-05-21.json \
  --pretty
```

Swift UI probe:

```bash
swift run --package-path mac-app Granite --read-api-ui-probe \
  --vault "/Users/heeung/Documents/Codex Vault" \
  --visible-note "<redacted-relative-path>"
```

## Pass Conditions

- Placeholder or partial UI state appears within `200ms`.
- Inspector visible tab reports `p95 <= 1s` and `p99 <= 3s` on the indexed real vault.
- Search first page reports `p95 <= 1s` and `p99 <= 3s` on the indexed real vault.
- Reports contain only redacted identifiers and aggregate timings.
