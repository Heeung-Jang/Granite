---
title: "Rust Engine Layered Architecture"
date: 2026-05-27
status: phase-0-baseline
---

# Rust Engine Layered Architecture

This document defines the target architecture for Granite's `vault-engine` Rust
crate. It is the Phase 0 baseline for
`docs/plans/2026-05-27-refactor-vault-engine-layered-architecture-plan.md`.

Related ownership documents:

- `docs/architecture/engine-boundary.md`
- `docs/architecture/save-safety.md`
- `docs/architecture/graph-view.md`
- `docs/benchmarks/read-api-ui-integration.md`
- `docs/benchmarks/vault-indexing-performance.md`

## Target Dependency Direction

```txt
ffi -> use_cases -> adapters -> core
ffi -> adapters   # composition-root handle construction/open/close only
use_cases -> adapters
adapters -> core
core -> no sqlite/tantivy/libc/fsevents/filesystem crawling
```

The first cleanup stays inside one Rust crate. A multi-crate workspace is
deferred until the module boundaries are stable.

## Layer Ownership

| Layer | Owns | Does Not Own |
| --- | --- | --- |
| `core` | Pure vault/domain records, metadata values, link keys, graph records, scan/file classification, search DTOs | SQLite, Tantivy, FSEvents, filesystem crawling, canonicalization, FFI buffers |
| `adapters::sqlite` | Metadata store, queue store, schema creation, SQL rows, SQLite FTS if retained in production | FFI row buffers, Swift payloads, Tantivy internals |
| `adapters::tantivy` | Search index, tokenizer setup, writer/searcher lifecycle, query parsing, snippets | FFI row buffers, SQLite store internals |
| `adapters::fs` | Vault root opening, canonicalization, symlink-safe resolution, scanner, note writer, index directory operations | SQL queries, Tantivy queries, FFI payloads |
| `adapters::fsevents` | macOS FSEvents raw API and event flag decoding | Use-case orchestration, FFI conversion |
| `use_cases` | Read surfaces, save orchestration, indexing/rebuild orchestration, startup reconciliation, watcher burst recovery, graph snapshot orchestration | C ABI, raw pointer handling, direct SQL/Tantivy/FSEvents calls |
| `ffi` | C ABI symbols, `#[repr(C)]` structs, panic containment, string/byte decoding, Rust-owned buffer lifecycle, Swift payload conversion | Business rules, SQL row decoding, parsing/indexing orchestration |
| `diagnostics` | Benchmarks, profiler-facing helpers, aggregate-only probe artifacts | Production runtime dependencies from core/use_cases/adapters/ffi |

## Visibility Rules

- Start internal modules as `pub(crate) mod`.
- Keep `pub` only for intentional Rust API, integration-test API, or Swift C
  ABI-facing structs/functions.
- Keep all Swift-decoded structs `#[repr(C)]`.
- Do not make Rust enum layout part of the ABI.
- Remove compatibility re-exports in a separate cleanup step after all callers
  migrate.

## Current Module Inventory

| Current Module Or Consumer | Target Placement | Notes |
| --- | --- | --- |
| `attachments` | `core/attachments.rs` | Attachment reference source, settings, and resolution state are domain values. |
| `benchmarks` | `diagnostics/benchmarks.rs` | Keep aggregate-only artifact rules. |
| `errors` | Layer-owned errors or a narrow cross-layer contract | Do not keep a global catch-all unless the contract is explicit. |
| `ffi` | `ffi/mod.rs` plus focused FFI files | Split panic, strings, health, read, save, graph, and buffers. |
| `file_watcher` | `adapters/fsevents/watcher.rs` | Raw FSEvents and platform flags stay in the adapter. |
| `graph` | `core/graph.rs` and `use_cases/build_graph.rs` | Pure graph records in core; snapshot construction orchestration in use cases. |
| `graph_key` | `core/links.rs` | Link key and unresolved target normalization are pure domain logic. |
| `index` | `core/metadata.rs` and `adapters/sqlite/metadata_store.rs` | Domain records move inward; schema, row decoding, and SQL stay in SQLite adapter. |
| `index_rebuild` | `adapters/fs/index_directory.rs` and `use_cases/index_rebuild.rs` | Path validation/mutation remains near filesystem operations. |
| `indexing_pipeline` | `use_cases/process_indexing_queue.rs`, `use_cases/scan_vault.rs`, adapters | Preserve streaming rebuild and bounded worker/channel settings. |
| `indexing_queue` | `adapters/sqlite/indexing_queue.rs` plus core queue records if needed | SQL lease/update details stay in adapter. |
| `parser` | `core/document.rs` for output types; parser implementation remains outside core until classified | Do not move IO or storage concerns into core. |
| `paths` | `core/paths.rs`, `core/files.rs`, `adapters/fs/path_resolver.rs` | Pure value types can move to core; canonicalization and metadata reads stay in adapter. |
| `read_api` | `use_cases/read_vault.rs`, `use_cases/live_preview_metadata.rs` | Read orchestration leaves FFI and storage details behind. |
| `read_ffi` | `ffi/read_rows.rs` | Binary row layout and row-kind constants are FFI-owned. |
| `save` | `use_cases/save_note.rs`, `adapters/fs/note_writer.rs`, `core` records where pure | Atomic writes and validation stay near filesystem adapter. |
| `scanner` | `adapters/fs/scanner.rs`, `core/scan.rs` | Filesystem walking stays in adapter; pure file classification can move to core. |
| `sqlite_fts` | `adapters/sqlite/fts_index.rs` or `diagnostics/sqlite_fts.rs` | Decide explicitly before public-surface cleanup. |
| `startup_reconciliation` | `use_cases/reconcile_startup.rs` | Startup orchestration depends on adapters. |
| `tantivy_search` | `adapters/tantivy/search_index.rs` | Tantivy schema, writer, reader, query, tokenizer, and snippet code. |
| `watcher_burst` | `use_cases/watcher_burst.rs` | Burst coalescing and recovery orchestration. |
| `bench/vault-profiler` | `diagnostics` facade or intentional public facade | Migrate imports before shrinking `lib.rs`. |

### Current Profiler Imports

`bench/vault-profiler` is a diagnostic consumer, so it may keep a narrow public
facade. These imports must be migrated before `lib.rs` visibility is reduced:

| File | Current Imports | Target |
| --- | --- | --- |
| `bench/vault-profiler/src/main.rs` | `vault_engine::benchmarks::{SnippetStorageMode, VaultBackendBenchmarkOptions, WholeVaultGraphBenchmarkOptions, run_shared_backend_benchmark_from_vault, run_whole_vault_graph_snapshot_benchmark}` | `diagnostics::benchmarks` facade. |
| `bench/vault-profiler/src/main.rs` | `vault_engine::tantivy_search::{TantivySearchError, TantivySearchIndex}` | `diagnostics` query benchmark facade or `adapters::tantivy` test-only facade. |
| `bench/vault-profiler/src/synthetic.rs` | `vault_engine::benchmarks` | `diagnostics::synthetic` or `diagnostics::benchmarks`. |
| `bench/vault-profiler/src/read_indexer.rs` | `attachments`, `index`, `parser`, `paths`, `read_api`, `scanner`, `sqlite_fts::SearchDocument`, `tantivy_search::TantivySearchIndex` | A single read-index materialization diagnostic facade. |
| `bench/vault-profiler/src/read_indexer.rs` | `read_api::{PageRequest, open_vault_read_api}` | A read-API benchmark diagnostic facade. |

## Target Module Shape

```txt
vault-engine/src/
  lib.rs
  core/
    mod.rs
    attachments.rs
    document.rs
    files.rs
    graph.rs
    links.rs
    metadata.rs
    paths.rs
    scan.rs
    search.rs
  use_cases/
    mod.rs
    build_graph.rs
    index_rebuild.rs
    live_preview_metadata.rs
    process_indexing_queue.rs
    read_vault.rs
    reconcile_startup.rs
    save_note.rs
    scan_vault.rs
    watcher_burst.rs
  adapters/
    mod.rs
    fs/
      mod.rs
      index_directory.rs
      note_writer.rs
      path_resolver.rs
      scanner.rs
      watcher.rs
    fsevents/
      mod.rs
      watcher.rs
    sqlite/
      mod.rs
      fts_index.rs
      indexing_queue.rs
      metadata_store.rs
    tantivy/
      mod.rs
      search_index.rs
  ffi/
    mod.rs
    buffers.rs
    graph.rs
    health.rs
    panic.rs
    read.rs
    read_rows.rs
    save.rs
    strings.rs
  diagnostics/
    mod.rs
    benchmarks.rs
    sqlite_fts.rs
```

The target tree is a guide, not a license to create empty modules. Create a file
only when existing code moves into it.

## Import Boundary Checks

Run these from the repository root after Phases 3, 4, 5, 6, and 7:

```sh
rg -n "std::fs|canonicalize|symlink_metadata|MetadataExt|OpenOptions|rename|remove_dir_all|rusqlite|tantivy|libc|FSEvent|extern \"C\"|unsafe|CStr|CString|no_mangle" vault-engine/src/core
rg -n "CStr|CString|c_char|c_uchar|no_mangle|extern \"C\"" vault-engine/src/use_cases vault-engine/src/adapters
rg -n "crate::ffi" vault-engine/src/core vault-engine/src/use_cases vault-engine/src/adapters
rg -n "crate::diagnostics" vault-engine/src/core vault-engine/src/use_cases vault-engine/src/adapters vault-engine/src/ffi
```

Any match must be removed or documented here as an explicit exception.

Allowed exceptions after Phase 1 FFI splitting:

- `vault-engine/src/ffi/` owns Rust-owned C ABI entry points, C string decoding, response buffers, and free functions.
- `vault-engine/src/file_watcher.rs` owns FSEvents until moved.
- `vault-engine/src/read_ffi.rs` owns FFI row buffers until moved.

## ABI Baseline Commands

Capture exported C symbols:

```sh
cargo build --manifest-path vault-engine/Cargo.toml --release
nm -gU vault-engine/target/release/libvault_engine.dylib | awk '{print $3}' | grep '^_engine_' | sort
```

Current symbol baseline:

- `docs/architecture/vault-engine-abi-symbols-baseline.txt`

Generate the layout manifest:

```sh
cargo run --manifest-path vault-engine/Cargo.toml --release --example abi_layout_manifest > docs/architecture/vault-engine-abi-layout-baseline.json
```

Current layout baseline:

- `docs/architecture/vault-engine-abi-layout-baseline.json`

The layout manifest includes `size_of`, `align_of`, field offsets, row-kind
constants, state constants, search/panel/depth constants, Swift-decoded numeric
semantic constants, JSON FFI payload field contracts, graph enum string values,
and known FFI error code strings. It is generated by the intentional
`diagnostics::abi_manifest` facade so future refactors can regenerate and diff it
instead of hand-maintaining offsets.

## Performance Guardrails

Preserve these existing caps and defaults unless a dedicated performance plan
changes them:

- Read page limit: `100`.
- File tree page limit: `100_000`.
- Graph nodes: `250`.
- Graph edges: `500`.
- Read/parse workers: `<= 4`.
- Channel capacity: `32`.
- Metadata batch size: `256`.
- Tantivy writer memory: `50MB`.

Do not add `collect::<Vec<_>>()`, broad `clone()`, `to_string()`, `format!()`,
`serde_json` round trips, `Box<dyn ...>`, or `Arc<dyn ...>` in hot paths unless
the change is justified and benchmarked.

Hot paths:

- File tree, search first page, inspector panels, properties, local graph, live
  preview metadata.
- Full rebuild scan/read/parse, SQLite metadata writes, Tantivy add/commit/reload.
- FFI binary read result buffer creation and free.

## Baseline Verification Commands

Rust tests:

```sh
cargo test --manifest-path vault-engine/Cargo.toml
```

Read row ABI layout tests after Phase 2 start:

```sh
cargo test --manifest-path vault-engine/Cargo.toml ffi::read_rows::
```

Swift engine smoke:

```sh
VAULT_ENGINE_DYLIB_PATH="$PWD/vault-engine/target/release/libvault_engine.dylib" \
  swift run --package-path mac-app Granite --engine-smoke-test
```

Fixture backend benchmark:

```sh
cargo run --manifest-path bench/vault-profiler/Cargo.toml --release -- backend-benchmark \
  --vault fixtures/compatibility-vault \
  --output docs/benchmarks/artifacts/vault-engine-architecture-fixture-baseline-2026-05-27.json \
  --work-dir docs/benchmarks/private/vault-engine-architecture-fixture-baseline-2026-05-27 \
  --corpus-id compatibility-fixture-vault-engine-architecture-baseline \
  --query Home \
  --query Guide \
  --time-to-usable-samples 3 \
  --pretty
```

Fixture read-index materialization:

```sh
cargo run --manifest-path bench/vault-profiler/Cargo.toml --release -- materialize-read-index \
  --vault fixtures/compatibility-vault \
  --metadata-path docs/benchmarks/private/vault-engine-architecture-read-index-fixture-2026-05-27/metadata.sqlite \
  --tantivy-path docs/benchmarks/private/vault-engine-architecture-read-index-fixture-2026-05-27/tantivy \
  --output docs/benchmarks/artifacts/vault-engine-architecture-read-index-fixture-baseline-2026-05-27.json \
  --force \
  --pretty
```

Fixture read API benchmark:

```sh
cargo run --manifest-path bench/vault-profiler/Cargo.toml --release -- read-api-benchmark \
  --vault fixtures/compatibility-vault \
  --metadata-path docs/benchmarks/private/vault-engine-architecture-read-index-fixture-2026-05-27/metadata.sqlite \
  --tantivy-path docs/benchmarks/private/vault-engine-architecture-read-index-fixture-2026-05-27/tantivy \
  --output docs/benchmarks/artifacts/vault-engine-architecture-read-api-fixture-baseline-2026-05-27.json \
  --query Home \
  --query Guide \
  --path Home.md \
  --path Docs/Guide.md \
  --pretty
```

Fixture Swift UI read probe:

```sh
VAULT_ENGINE_DYLIB_PATH="$PWD/vault-engine/target/release/libvault_engine.dylib" \
  swift run --package-path mac-app Granite --read-api-ui-probe \
  --vault-root fixtures/compatibility-vault \
  --output docs/benchmarks/artifacts/vault-engine-architecture-read-api-ui-fixture-baseline-2026-05-27.json
```

Real-vault read UI probe:

```sh
VAULT_ENGINE_DYLIB_PATH="$PWD/vault-engine/target/release/libvault_engine.dylib" \
  swift run --package-path mac-app Granite --read-api-ui-probe \
  --vault-root "/Users/heeung/Documents/Codex Vault" \
  --output docs/benchmarks/artifacts/vault-engine-architecture-read-api-ui-real-redacted-baseline-2026-05-27.json
```

Real-vault backend benchmark, if a private query file is available:

```sh
cargo run --manifest-path bench/vault-profiler/Cargo.toml --release -- backend-benchmark \
  --vault "/Users/heeung/Documents/Codex Vault" \
  --output docs/benchmarks/artifacts/vault-engine-architecture-real-redacted-baseline-2026-05-27.json \
  --work-dir docs/benchmarks/private/vault-engine-architecture-real-baseline-2026-05-27 \
  --corpus-id real-vault-redacted-vault-engine-architecture-baseline \
  --query-file docs/benchmarks/private/<private-query-file>.txt \
  --skip-sqlite-fts \
  --time-to-usable-samples 3 \
  --pretty
```

The committed real-vault backend baseline was captured from a private two-query
set. The raw query strings are intentionally not documented or committed; the
query set identifier is
`sha256:2ad2b76e7b4b81d40c1e2244f1919d89ff600b55ad3cb6391e23f5ac5d10a4d7`.

Swift UI probe artifacts are SwiftPM debug app probes using the release Rust
dylib through `VAULT_ENGINE_DYLIB_PATH`. Treat them as integration smoke and
no-worse UI baselines. Backend performance gates use release profiler artifacts.

## Phase 0 Baseline Artifacts

Captured on 2026-05-27 before architecture-moving changes:

| Artifact | Scope | Notes |
| --- | --- | --- |
| `docs/architecture/vault-engine-abi-symbols-baseline.txt` | C ABI symbols | `18` exported `_engine_*` symbols. |
| `docs/architecture/vault-engine-abi-layout-baseline.json` | C ABI layout and JSON FFI contracts | Generated from `cargo run --manifest-path vault-engine/Cargo.toml --release --example abi_layout_manifest`. |
| `docs/benchmarks/artifacts/vault-engine-architecture-fixture-baseline-2026-05-27.json` | Fixture indexing baseline | Release build, `6` Markdown docs, time-to-usable `153,038us`, peak RSS `34,996,224` bytes. |
| `docs/benchmarks/artifacts/vault-engine-architecture-read-index-fixture-baseline-2026-05-27.json` | Fixture read index materialization | Release build, `9` indexed files, `187.58ms`, privacy flags false for raw bodies/paths/absolute paths. |
| `docs/benchmarks/artifacts/vault-engine-architecture-read-api-fixture-baseline-2026-05-27.json` | Fixture read API benchmark | File tree p95 `0.248ms`, file-name search p95 `0.645ms`, backlinks p95 `0.172ms`. |
| `docs/benchmarks/artifacts/vault-engine-architecture-read-api-ui-fixture-baseline-2026-05-27.json` | Fixture Swift UI read probe | Passed; file tree p95 `0.186ms`, search p95 `0.031ms`, inspector p95 `0.354ms`. |
| `docs/benchmarks/artifacts/vault-engine-architecture-read-api-ui-real-redacted-baseline-2026-05-27.json` | Real-vault Swift UI read probe | Command and hard ceiling passed; search p95 `53.308ms`, inspector p95 `2.524ms`, file tree p95 `1318.858ms`. File tree exceeds the target `<=1s`, so keep it as a no-worse watch item for this architecture refactor. |
| `docs/benchmarks/artifacts/vault-engine-architecture-real-redacted-baseline-2026-05-27.json` | Real-vault backend baseline | Release build, `64,306` Markdown docs, `3,182,796,819` bytes, time-to-usable samples `120.90s`, `159.90s`, `171.50s`, Tantivy initial index `67.82s`, peak RSS `2,075,361,280` bytes. |

The backend artifact field `run_metadata.sample_count` currently represents
query sample count. For time-to-usable regression gates, use the explicit length
and values of `time_to_usable_samples`.

## Phase 0 Verification Evidence

Captured on 2026-05-27:

| Check | Command | Result |
| --- | --- | --- |
| Rust format | `cargo fmt --manifest-path vault-engine/Cargo.toml --check` | Passed after formatting. |
| Rust tests | `cargo test --manifest-path vault-engine/Cargo.toml` | Passed: `158` passed, `1` ignored. |
| Release Rust build | `cargo build --manifest-path vault-engine/Cargo.toml --release` | Passed. |
| ABI layout JSON | `cargo run --manifest-path vault-engine/Cargo.toml --release --example abi_layout_manifest` and `python3 -m json.tool` | Passed. |
| Swift engine smoke | `VAULT_ENGINE_DYLIB_PATH="$PWD/vault-engine/target/release/libvault_engine.dylib" swift run --package-path mac-app Granite --engine-smoke-test` | Passed with `loaded: vault-engine:ok:abi=1`. |
| Fixture backend benchmark | `vault-profiler backend-benchmark` release command above | Passed and wrote aggregate-only artifact. |
| Fixture read index | `vault-profiler materialize-read-index` release command above | Passed and wrote aggregate-only artifact. |
| Fixture read API | `vault-profiler read-api-benchmark` release command above | Passed and wrote aggregate-only artifact. |
| Fixture Swift UI probe | `swift run --read-api-ui-probe` command above | Passed. |
| Real-vault Swift UI probe | `swift run --read-api-ui-probe` command above | Passed hard ceiling; file tree p95 is a watch item. |
| Real-vault backend benchmark | `vault-profiler backend-benchmark` release command above | Passed and wrote aggregate-only artifact. |

Privacy check:

```sh
rg -n "/Users/heeung|Codex Vault|Compound engineering|Agents.md|Obsidian|Codex" docs/benchmarks/artifacts/*.json
```

The command returned no matches for the Phase 0 artifacts.

The grep is a secondary guard. Public benchmark artifacts must also be checked
against an allowlist:

- They may include aggregate counts, timing summaries, hashes, run metadata,
  privacy flags, and redacted labels.
- They must not include raw note bodies, snippets from private notes, raw query
  strings, raw paths, absolute vault paths, file IDs, title values, tag values,
  or frontmatter values.
- Artifacts with privacy flags must keep `raw_note_bodies_committed`,
  `raw_paths_committed`, and `absolute_paths_committed` false.

## Rollback Policy

- Phase 0 is documentation and baseline only.
- Each later RA task should be independently revertible.
- Prefer one commit per RA task during implementation.
- For file moves, first commit the mechanical move with minimal import fixes.
- If tests fail after a semantic extraction, revert only the latest extraction
  commit.
- Keep temporary compatibility re-exports until all callers are migrated and
  verified.
- Remove compatibility shims in a separate cleanup commit.
- Do not proceed to the next phase when the current phase gate fails.

## Phase 1 FFI Split Checklist

Move these groups one at a time and run the matching gate before continuing:

| Task | Group | Target |
| --- | --- | --- |
| RA01.01 | Existing module body | `vault-engine/src/ffi/mod.rs` |
| RA01.02 | Panic containment | `vault-engine/src/ffi/panic.rs` |
| RA01.03 | C string and byte decoding | `vault-engine/src/ffi/strings.rs` |
| RA01.04-RA01.04a | JSON response envelope and JSON DTO contracts | `vault-engine/src/ffi/json.rs` or focused save/graph modules |
| RA01.05-RA01.05b | Read open, rebuild, page buffers, and read error/state mapping | `vault-engine/src/ffi/read.rs` |
| RA01.06 | ABI version and health | `vault-engine/src/ffi/health.rs` |
| RA01.06a | Rust-owned string/read-buffer lifecycle | `vault-engine/src/ffi/lifecycle.rs` |
| RA01.07 | Save FFI entry points and save DTOs | `vault-engine/src/ffi/save.rs` |
| RA01.08 | Whole-vault graph FFI entry point and graph DTOs | `vault-engine/src/ffi/graph.rs` |
| RA01.09-RA01.11 | Compatibility, symbol comparison, boundary scan, invalid-input regressions | `crate::ffi` remains the public Rust module path |

## Placement Checklist For New Rust Code

- New domain record or pure value conversion: `core`.
- New SQLite query, row decoder, schema, or transaction: `adapters::sqlite`.
- New Tantivy schema, query, tokenizer, writer, or searcher code:
  `adapters::tantivy`.
- New filesystem traversal, canonicalization, save/write primitive, or index
  directory mutation: `adapters::fs`.
- New FSEvents call or event flag decoding: `adapters::fsevents`.
- New user/system workflow orchestration: `use_cases`.
- New C ABI entry point, raw pointer, C string, Swift row layout, or JSON envelope:
  `ffi`.
- New benchmark/probe helper: `diagnostics`.
