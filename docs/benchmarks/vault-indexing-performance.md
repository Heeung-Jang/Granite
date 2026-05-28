---
title: "Vault Indexing Performance"
date: 2026-05-21
status: in_progress
---

# Vault Indexing Performance

## Scope

This report tracks the targeted indexing work after the Tantivy backend decision.
The goal is to improve full vault indexing and time-to-usable behavior without
changing the selected backend split: Tantivy for search and SQLite for metadata.

## Baseline And Targets

| Metric | Current baseline | Required target | Stretch target |
| --- | ---: | ---: | ---: |
| Full real-vault Tantivy indexing | `174.42s` | `<= 116s` | `<= 58s` |
| Time to usable p95 | TBD | `p95 <= 5s` | `p95 <= 3s` |
| Time to usable p99 | TBD | `p99 <= 10s` | TBD |
| Placeholder or partial result response | TBD | `<= 200ms` | TBD |

The full indexing target keeps the existing real-vault bake-off as the baseline:
`docs/benchmarks/artifacts/backend-bakeoff-real-2026-05-19.json`.

## Privacy Policy

- Do not commit raw vault paths, raw query text, snippets, note titles, or note bodies.
- Commit aggregate-only JSON artifacts under `docs/benchmarks/artifacts/`.
- Store raw/private run data under ignored `docs/benchmarks/private/`.
- Use redacted corpus identifiers in public reports.

## Fixture Command

```bash
cargo run --manifest-path bench/vault-profiler/Cargo.toml -- backend-benchmark \
  --vault fixtures/compatibility-vault \
  --output docs/benchmarks/artifacts/<fixture-artifact>.json \
  --work-dir docs/benchmarks/private/<fixture-run-id> \
  --corpus-id compatibility-fixture-indexing-performance \
  --query Home \
  --query Guide \
  --pretty
```

## Real-Vault Command

```bash
cargo run --manifest-path bench/vault-profiler/Cargo.toml -- backend-benchmark \
  --vault <private-vault-path> \
  --output docs/benchmarks/artifacts/<redacted-real-vault-artifact>.json \
  --work-dir docs/benchmarks/private/<real-run-id> \
  --corpus-id real-vault-redacted-indexing-performance \
  --query-file docs/benchmarks/private/<private-query-file>.txt \
  --skip-sqlite-fts \
  --pretty
```

## Artifact Log

| Date | Artifact | Run condition | Scope | Notes |
| --- | --- | --- | --- | --- |
| 2026-05-19 | `docs/benchmarks/artifacts/backend-bakeoff-real-2026-05-19.json` | warm local run | baseline | Tantivy full indexing `174.42s`; aggregate-only public artifact. |
| 2026-05-21 | `docs/benchmarks/artifacts/vault-indexing-fixture-2026-05-21.json` | release, streaming_vault | fixture | Schema 7 artifact with scan, metadata, read/parse, Tantivy add/commit/reload, and time-to-usable samples. |
| 2026-05-21 | `docs/benchmarks/artifacts/vault-indexing-real-redacted-2026-05-21.json` | release, streaming_vault | real vault | Tantivy-only acceptance run with SQLite metadata; public artifact passed privacy review. |

## Fixture Stage Check

The compatibility fixture is too small to represent real-vault throughput, but it
verifies that the benchmark artifact is aggregate-only and contains the stage
breakdown needed for acceptance analysis.

| Metric | 2026-05-19 fixture baseline | 2026-05-21 stage artifact |
| --- | ---: | ---: |
| Artifact schema | `1` | `7` |
| Document count | `6` | `6` |
| Query count | `4` | `4` |
| Tantivy initial indexing | `151,178us` | `161,231us` |
| Tantivy query p95 / p99 | `857us / 857us` | `726us / 726us` |
| Scan | not captured | `205us` |
| SQLite metadata write | not captured | `243us` |
| Read/parse combined p95 | not captured | `180us` |
| Tantivy add / commit / reload | not captured | `32us / 158,594us / 1,666us` |
| Time-to-usable samples | not captured | `161,716us`, `175,189us`, `182,702us` |

Fixture bottleneck: Tantivy commit dominates this tiny corpus, so fixture numbers
are used only as instrumentation and privacy evidence. Real-vault gate decisions
must use the redacted real-vault artifact.

## Real-Vault Gate Check

The real-vault acceptance run used `--skip-sqlite-fts` because SQLite FTS is not
the selected production search backend. A prior SQLite-FTS-inclusive run reached
large ignored private files and was stopped before any public artifact was
created. A prior metadata run without child lookup indexes also exceeded 35
minutes in metadata writes; child lookup indexes were added before the accepted
run below.

| Metric | Baseline / target | 2026-05-21 result | Status |
| --- | ---: | ---: | --- |
| Full metadata + Tantivy usable time | target `<= 116s` | `100.82s` | Pass |
| Improvement over `174.42s` baseline | target `>= 1.5x` | `1.73x` | Pass |
| Tantivy indexing only | stretch `<= 58s` | `63.07s` | Miss |
| Complete time-to-usable sample count | report sample count | `1` | Limited |
| Complete time-to-usable sample | target p95 `<= 5s`, p99 `<= 10s` | `100.82s` | Miss |
| Placeholder / partial response | target `<= 200ms` | not measured by CLI artifact | Deferred |
| Peak RSS | target `<= 1.5GB`, baseline `1.63GB` | `2.09GB` | Miss |
| Tantivy query p95 / p99 | no material regression | `50.70ms / 50.70ms` | Watch |

Dominant stages in the accepted real-vault artifact:

| Stage | Time |
| --- | ---: |
| Tantivy add | `39.11s` |
| SQLite metadata write | `34.53s` |
| Tantivy commit | `19.77s` |
| Scan + source collection | `3.22s` |
| Tantivy reader reload | `34.02ms` |

Corpus shape from the same artifact:

| Count | Value |
| --- | ---: |
| Markdown documents | `64,306` |
| Total document bytes | `3.18GB` |
| Metadata links | `1,987,481` |
| Metadata tags | `280,090` |
| Metadata properties | `513,468` |
| Metadata headings | `5,152,200` |
| Metadata attachments | `1,409,428` |

The first gate passes, but default promotion should not claim the stretch gate or
time-to-usable gate. The next performance work should target Tantivy add time,
metadata write volume, and peak RSS.

## Default Configuration Decision

| Setting | Decision | Reason |
| --- | --- | --- |
| Read/parse workers | Keep default `4` cap | Real-vault read/parse p95 is `1.73ms`; not the dominant bottleneck. |
| Channel capacity | Keep `32` | Bounded in-flight behavior is verified; no evidence that queue capacity is limiting the accepted run. |
| Metadata batch size | Keep `256` | Batch writes plus child lookup indexes completed the real-vault metadata stage in `34.53s`; further tuning should be isolated. |
| Tantivy writer memory | Keep `50MB` | Current run passes the first gate, while RSS already misses target at `2.09GB`. |
| Tantivy writer threads | Keep Tantivy default | No accepted real-vault artifact proves a better thread setting. |
| Snippet storage mode | Keep `stored_body` | Lazy source remains experimental and currently returns empty search snippets in the benchmark path. |
| SQLite FTS backend | Exclude from real-vault acceptance | Tantivy is the selected search backend; SQLite FTS-inclusive real run was too large and not needed for the gate. |

## Artifact Schema Notes

- Existing `schema_version: 1` bake-off artifacts from 2026-05-19 remain aggregate-only and do not contain run metadata or stage timing breakdowns.
- `schema_version: 2` artifacts add redacted run metadata.
- `schema_version: 3` artifacts add stage metrics.
- `schema_version: 4` artifacts add Tantivy document count fields for rebuild and replace paths.
- `schema_version: 5` artifacts add bounded pipeline configuration and read/parse in-flight counts.
- `schema_version: 6` artifacts add SQLite metadata write timing and table counts.
- Current `schema_version: 7` artifacts add aggregate time-to-usable timing.
- Stage fields must stay aggregate-only: no raw query text, note content, snippets, full note-relative paths, or raw vault paths.
