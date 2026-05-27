---
title: "refactor: Introduce Layered Rust Engine Architecture"
type: refactor
date: 2026-05-27
deepened_on: 2026-05-27
deepened_passes: 4
brainstorm: docs/brainstorms/2026-05-27-rust-engine-architecture-brainstorm.md
---

# refactor: Introduce Layered Rust Engine Architecture

## Overview

Refactor Granite's Rust `vault-engine` into a layered single-crate architecture:

```txt
ffi -> use_cases -> adapters -> core
ffi -> adapters   # composition-root handle construction/open/close only
use_cases -> adapters
adapters -> core
core -> no sqlite/tantivy/libc/fsevents/filesystem crawling
```

The selected approach comes from `docs/brainstorms/2026-05-27-rust-engine-architecture-brainstorm.md`: **Core + Use Cases + Adapters + Thin FFI**, scored `9.1 / 10`.

This plan intentionally keeps one Rust crate for the first architecture cleanup. A multi-crate workspace is deferred until internal boundaries are stable.

## Deepening Summary

This deepening adds four specialist review passes and tightens the original plan around architecture, simplicity, performance, and security risks:

- Separate **mechanical moves** from **semantic extraction**. A task should either move code without changing behavior or extract a boundary with new verification, not both.
- Add explicit **import boundary checks** so the new `core`, `ffi`, `adapters`, and `use_cases` names cannot drift immediately after the refactor.
- Add an **ABI symbol gate** before and after the FFI split, because Swift loads C symbols at runtime.
- Keep **rollback points** at phase boundaries. If a phase fails, the next phase should not start until the current phase is green.
- Keep **adapter traits deferred**. The architecture should be enforced by modules first, not by speculative traits.

### Section Manifest

| Section | Deepening Focus |
| --- | --- |
| Proposed Architecture | Add layer invariants and import rules that can be checked with `rg`. |
| Implementation Phases | Split broad moves into compile-safe, reviewable units with phase gates. |
| Verification Plan | Add ABI symbol comparison, architecture import scans, and privacy/performance gates. |
| Risks | Add rollback, circular dependency, and accidental public API risks. |
| Acceptance Criteria | Add measurable layer purity and compatibility criteria. |

## Problem Statement

`vault-engine` grew feature by feature and now has weak internal boundaries:

- `lib.rs` exposes almost every internal module as `pub mod`.
- `ffi.rs` mixes C ABI functions, panic handling, string decoding, JSON response envelopes, read paging, save conversion, graph conversion, and tests.
- `index.rs` mixes domain records, SQLite schema, SQL queries, projection models, row decoders, conversion helpers, and tests.
- `read_api.rs` directly knows graph, metadata store, parser, scanner classification, SQLite result types, and Tantivy search.
- `indexing_pipeline.rs` mixes scan source creation, filesystem reads, Markdown parsing, metadata conversion, queue processing, SQLite writes, Tantivy writes, metrics, and tests.

The result is slower feature work, higher regression risk, and unclear ownership between domain semantics, storage adapters, FFI, and orchestration.

## Goals

- Make Rust module boundaries explicit and enforceable.
- Preserve the existing Swift-facing C ABI behavior.
- Keep the current single `vault-engine` crate and package flow.
- Reduce large modules through compile-safe, behavior-preserving moves.
- Move business orchestration into use-case modules.
- Move SQLite, Tantivy, filesystem, and FSEvents details into adapter modules.
- Keep `core` independent from storage, FFI, and OS-specific dependencies.
- Use `pub(crate)` by default and `pub` only for intentional Rust API or C ABI-facing structs/functions.
- Keep performance hot paths allocation-conscious.
- Add or update architecture documentation so future Rust work has clear placement rules.

## Non-Goals

- Do not create a multi-crate workspace in this pass.
- Do not change Swift call sites unless an existing import path requires a mechanical update.
- Do not change C symbol names, ABI layout, read row layout, or JSON payload shape.
- Do not change SQLite schema, Tantivy schema, indexing behavior, graph membership, save semantics, or parser output.
- Do not introduce broad trait abstractions unless a test or alternate backend actually needs one.
- Do not optimize indexing/search performance during this refactor.
- Do not rewrite tests wholesale; move or add focused tests only where boundaries are split.

## Research Summary

### Local Findings

- `docs/architecture/engine-boundary.md` already states that Swift owns macOS presentation and Rust owns vault semantics, indexing state, query execution, and returned data.
- `docs/architecture/save-safety.md` assigns save validation and write primitives to Rust, while Swift owns user prompts and dirty state.
- `docs/architecture/graph-view.md` assigns graph membership and FFI payload validity to Rust, presentation to Swift.
- `docs/benchmarks/read-api-ui-integration.md` defines real-vault read API gates: inspector/search p95 `<= 1s`, p99 `<= 3s`.
- `docs/benchmarks/vault-indexing-performance.md` warns that memory is a gate and real-vault artifacts must stay aggregate-only.
- `docs/solutions/` does not exist in this repository, so there are no institutional solution notes to reuse.

### External Findings From Brainstorm

- `rust-analyzer` uses explicit API boundaries and keeps LSP/serialization at the outer crate boundary.
- `rust-analyzer` separates abstract model from build-system/filesystem-specific models.
- Nushell uses `nu-protocol` to avoid recursive dependencies between many crates.
- Tantivy separates index, schema, writer, searcher, directory, tokenizer, and query roles.
- Rust API Guidelines emphasize intentional public API, meaningful errors, private fields, and future-proofing.

## Proposed Architecture

### Target Module Shape

Final target for this refactor series:

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

The exact file names may be adjusted during implementation if the existing code points to a cleaner split. The dependency direction must not change.

Target placement notes:

- `core/attachments.rs` owns attachment reference enums/settings/states only.
- `core/scan.rs` or `core/files.rs` owns scan result records and pure file-kind classification.
- `core/links.rs` owns wikilink/link-key normalization, including unresolved graph target keys.
- `core/search.rs` owns stable search document/result DTOs shared by search adapters.
- `adapters/fs/path_resolver.rs` owns vault root opening, canonicalization, and symlink-safe resolution.
- `adapters/fs/note_writer.rs` owns temp writes, permission preservation, and atomic replacement.
- `adapters/fs/index_directory.rs` owns rebuild directory validation, swap, and abort cleanup.
- `adapters/fsevents/watcher.rs` owns macOS FSEvents raw API and flag decoding.
- SQLite FTS must be classified explicitly as either `adapters/sqlite/fts_index.rs` if retained in production or `diagnostics/sqlite_fts.rs` if benchmark-only.
- `errors.rs` should not remain a global catch-all unless it becomes a real cross-layer contract; prefer layer-owned errors mapped outward.

### Visibility Rule

- `lib.rs` should expose only intentional stable surfaces.
- Internal modules should start as `pub(crate) mod`.
- Public Rust structs should avoid exposing adapter-specific dependencies unless they are already part of a stable contract.
- FFI structs crossing Swift/Rust must stay `#[repr(C)]`.
- Rust enum layout must not become an ABI contract.

### Adapter Rule

Adapters own concrete dependencies:

- SQLite/rusqlite: metadata store, queue store, schema creation, SQL rows.
- Tantivy: search index, writer options, tokenizer setup, query parsing, snippet generation.
- Filesystem: scanner, file identity, file reads, path resolution that touches disk.
- FSEvents: watcher implementation and macOS-specific event decoding.

Core types may represent `FileIdentity`, paths, links, metadata records, graph records, and parsed document concepts, but core should not open files or databases.

### Use-Case Rule

Use cases orchestrate work:

- Read vault surfaces: file tree, search, inspector panels, local graph, live preview metadata.
- Save note: baseline capture, safe save, conflict choices.
- Indexing: scan, rebuild, queue batch processing, startup reconciliation, watcher burst recovery.
- Graph: whole-vault and local graph snapshot construction.

Use cases may call adapters and core, but they should not expose adapter internals to FFI or Swift.

### Boundary Invariants

Each implementation phase must preserve these invariants:

| Layer | Allowed To Import | Must Not Import |
| --- | --- | --- |
| `core` | `std`, pure domain modules | `rusqlite`, `tantivy`, `libc`, `std::fs`, FSEvents, FFI buffers |
| `adapters::sqlite` | `core`, `rusqlite` | `ffi`, Swift-facing row buffers |
| `adapters::tantivy` | `core`, `tantivy` | `ffi`, SQLite store internals |
| `adapters::fs` | `core`, filesystem APIs | `ffi`, SQLite query APIs, Tantivy search APIs |
| `use_cases` | `core`, `adapters` | `libc`, C string decoding, Swift row buffers |
| `ffi` | `use_cases`, `core`, selected adapter constructors, `libc` | SQL row decoders, parsing/indexing business rules |
| `diagnostics` | all production layers through public/internal facades | raw private note text in committed artifacts |

Additional dependency rules:

- `ffi -> adapters` is allowed only for composition-root handle construction/open/close. Query, save, index, graph, and metadata decisions should flow through use cases.
- Adapters must not import sibling adapters. Shared DTOs move inward to `core` or outward to `use_cases`.
- Final-state use cases must not import `rusqlite`, `tantivy`, `libc`, FSEvents, or `std::fs` directly.
- Diagnostics may depend inward on use cases/adapters/core; no production module may import diagnostics.
- `core` should not derive or own serialization DTOs just because FFI or benchmark JSON needs them. FFI JSON DTOs stay in `ffi`; benchmark artifact DTOs stay in `diagnostics`.

Recommended import checks after each phase:

```sh
rg -n "rusqlite|tantivy|libc|std::fs|fsevent|FSEvent" vault-engine/src/core
rg -n "CStr|CString|c_char|c_uchar|no_mangle|extern \"C\"" vault-engine/src/core vault-engine/src/use_cases vault-engine/src/adapters
rg -n "crate::ffi" vault-engine/src/core vault-engine/src/use_cases vault-engine/src/adapters
```

Expected result: no matches except explicit documented exceptions in `docs/architecture/rust-engine.md`.

### Safety Invariants

- FFI unsafe boundary: `#[unsafe(no_mangle)]`, `extern "C"`, raw pointer decoding, `CString::from_raw`, `Vec::from_raw_parts`, `CStr::from_ptr`, and `slice::from_raw_parts` stay confined to `ffi`, `ffi/read_rows`, the FSEvents adapter, or diagnostics-only libc code. No raw pointer or FFI buffer type reaches `core` or `use_cases`.
- ABI layout: all `#[repr(C)]` read/result/save structs, row-kind constants, state codes, error codes, JSON envelope keys, field order, `size_of`, `align_of`, and field offsets are frozen unless the refactor explicitly declares an ABI migration.
- FFI ownership: Rust allocates returned strings/buffers and only the matching Rust free function releases them. Null free/close remains a no-op. Invalid null/UTF-8/byte inputs return structured errors. Panics never cross FFI.
- Path safety: write/delete/rename/link/rebuild operations only use `VaultRoot` plus normalized relative paths or validated `IndexRebuildPaths`. All destructive operations revalidate canonical parent/target immediately before mutation and reject absolute paths, traversal, URL schemes, tilde, NUL, symlink escapes, non-regular files, and vault/index overlap.
- Core purity: `core` may contain path value types, but not filesystem resolution, `FileIdentity::from_metadata`, canonicalization, `MetadataExt`, SQLite, Tantivy, FSEvents, or libc.
- Privacy: committed diagnostics/probe/benchmark artifacts remain aggregate-only. No note body, snippets, tags, frontmatter values, query strings, file IDs, raw relative paths, or full private paths. Private payloads must require an explicit private output path under an ignored directory.

### Performance Guardrails

This refactor must be performance-neutral. It should not attempt to improve indexing/search performance, but it must not make known hot paths worse.

Hot paths:

- Read pages: file tree, search first page, inspector panels, properties, local graph, live preview metadata.
- Graph snapshots: local and whole-vault graph node/edge/tag collection.
- Indexing: queue batch processing, full rebuild read/parse, SQLite metadata writes, Tantivy add/commit/reload.
- FFI: binary read result buffer conversion and Rust-owned buffer free.

Preserve current caps and defaults unless a separate performance plan changes them:

- Read page limit: `100`.
- File tree page limit: `100_000`.
- Graph nodes: `250`.
- Graph edges: `500`.
- Read/parse workers: `<= 4`.
- Channel capacity: `32`.
- Metadata batch size: `256`.
- Tantivy writer memory: `50MB`.

No-allocation rules for hot paths:

- Do not add `collect::<Vec<_>>()`, broad `clone()`, `to_string()`, `format!()`, `serde_json` round trips, `Box<dyn ...>`, or `Arc<dyn ...>` in hot paths unless the change is justified and benchmarked.
- FFI may allocate only for final output ownership or existing JSON envelopes.
- Read rows must stay binary/buffer-based, not converted through JSON.
- Full rebuild must keep streaming into Tantivy. Do not introduce a full-corpus `Vec<SearchDocument>`.
- Queue processing may keep bounded batch vectors only. Do not turn lease-limited processing into whole-vault materialization.
- Adapters must not reopen SQLite/Tantivy per read page or search call.

### Refactor Discipline

Use this sequence for every file split:

1. Move code without edits.
2. Fix imports only.
3. Run the narrowest relevant test.
4. Commit or mark the step complete.
5. Extract or rename only after the mechanical move is green.

Avoid mixing file moves, visibility changes, function rewrites, and test rewrites in one task.

### Simplicity Guardrails

- Treat the target module tree as a candidate shape, not a required final file list.
- Do not create empty leaf modules. Create a file only when existing code is moved into it.
- Each implementation patch should do one of:
  - mechanical file move only,
  - import path update only,
  - extraction of one cohesive helper group only.
- Do not move code and redesign APIs in the same patch.
- Stop after Phase 2 and re-check whether Phase 3+ still needs the same shape.
- Prefer concrete `pub(crate)` structs and functions over interfaces.

### Anti-Patterns

Avoid these outcomes explicitly:

- Splitting `ffi.rs` into files but leaving orchestration there.
- Letting `use_cases` become a renamed dumping ground for `read_api.rs` or `indexing_pipeline.rs`.
- Moving whole files into `core` when they contain filesystem work, especially `paths.rs`, `scanner.rs`, and parts of `save.rs`.
- Letting SQLite projection structs or Tantivy result structs become FFI/read API contracts.
- Keeping compatibility re-exports like `read_ffi`, `index`, `tantivy_search`, or `indexing_queue` beyond one migration phase.
- Adding repository traits only to satisfy layering; prefer concrete adapters unless a second backend or focused test seam exists.

### Trait Rule

Do not introduce new traits, repository interfaces, generic adapter abstractions, or `dyn` dispatch during this refactor.

Exception: a trait is allowed only when both are true:

- A named production caller needs polymorphism now.
- A focused test cannot be written cleanly with the concrete type.

Otherwise use concrete `pub(crate)` structs/functions.

## Spec Flow Analysis

| Flow | Actor | Start | Expected End |
| --- | --- | --- | --- |
| F1 | Developer | Move one helper group from `ffi.rs` | `cargo test` passes and C symbols remain unchanged |
| F2 | Swift app | Calls existing engine read/save functions | Same payloads and errors as before |
| F3 | Developer | Extract pure records to `core` | Adapter modules compile against core records without behavior changes |
| F4 | Developer | Extract SQLite/Tantivy adapters | Use cases call adapter APIs; query/indexing tests still pass |
| F5 | Developer | Reduce `lib.rs` public surface | In-crate tests pass; package still bundles `libvault_engine.dylib` |
| F6 | Release verification | Package app | Packaged probes pass with the refactored engine |

Important edge cases:

- Panic containment must still convert panics to structured FFI errors.
- Null pointer handling must remain null-safe at free/close functions.
- Read result buffers must preserve layout and free ownership rules.
- Save JSON payloads must preserve existing `ok/value/error` envelopes.
- Rebuild path validation must still protect the vault from deletes.
- Benchmark artifacts must not gain raw note text or private paths.

Resolved deepening decisions:

- Default dependency flow is `ffi -> use_cases -> adapters -> core`.
- Direct `ffi -> adapters` access is limited to handle construction/open/close.
- Foundational domain types move before metadata records.
- Diagnostics/profiler migration must happen before public-surface cleanup.
- Compatibility re-exports are temporary and must be removed in a separate cleanup step.

If implementation uncovers a conflict between target naming and existing Rust module constraints, prefer the smallest compile-safe move and document the deviation in `docs/architecture/rust-engine.md`.

## Phase Gate Policy

- Phase 0 is documentation and baseline only. It must not change Rust behavior.
- Phase 1 and Phase 2 are ABI-sensitive. They require symbol comparison before continuing.
- Phase 3 must not introduce storage adapters. It only extracts pure domain types, starting with foundational path/file/scan/parser/attachment/link/search DTOs.
- Phase 4 must not change SQL, schema, query ordering, Tantivy schema, tokenizer config, or writer options.
- Phase 5 must not change user-visible behavior. It only moves orchestration behind clearer module names.
- Phase 6 migrates diagnostics/profiler-facing Rust consumers before public-surface cleanup.
- Phase 7 is the first phase allowed to reduce public Rust module exposure.

Stop at the end of any phase if a gate fails. Do not proceed by compensating in a later phase.

## Implementation Phases

### Phase 0: Baseline And Architecture Guardrails

- [x] **RA00.01 Add Rust engine architecture doc**
  - Build: create `docs/architecture/rust-engine.md` with layer definitions, dependency rules, visibility rules, and hot-path performance rules.
  - Verify: doc links to `docs/architecture/engine-boundary.md`, `save-safety.md`, and `graph-view.md`.

- [x] **RA00.02 Capture current module inventory**
  - Build: add a short table in `docs/architecture/rust-engine.md` mapping current modules to target layers.
  - Verify: table includes `attachments`, `benchmarks`, `errors`, `ffi`, `file_watcher`, `graph`, `graph_key`, `index`, `index_rebuild`, `indexing_pipeline`, `indexing_queue`, `parser`, `paths`, `read_api`, `read_ffi`, `save`, `scanner`, `sqlite_fts`, `startup_reconciliation`, `tantivy_search`, `watcher_burst`, and `bench/vault-profiler` imports.

- [x] **RA00.03 Run baseline Rust tests**
  - Build: no code changes.
  - Verify: `cargo test --manifest-path vault-engine/Cargo.toml`.

- [x] **RA00.04 Run baseline Swift engine smoke**
  - Build: no code changes.
  - Verify: `swift run --package-path mac-app Granite --engine-smoke-test`.

- [x] **RA00.05 Record baseline ABI symbol list**
  - Build: capture current exported `engine_*` symbols from release dylib after a local Rust build.
  - Verify: symbol list includes health, string free, read open/close/free, read surfaces, save, graph, and rebuild functions.

- [x] **RA00.06 Add ABI symbol capture command to docs**
  - Build: document the exact command in `docs/architecture/rust-engine.md`.
  - Verify:
    ```sh
    cargo build --manifest-path vault-engine/Cargo.toml --release
    nm -gU vault-engine/target/release/libvault_engine.dylib | awk '{print $3}' | grep '^_engine_' | sort
    ```

- [x] **RA00.07 Add boundary scan commands to docs**
  - Build: add import scan commands for `core`, `adapters`, `use_cases`, and `ffi` to `docs/architecture/rust-engine.md`.
  - Verify: commands are copy-paste runnable from repo root.

- [x] **RA00.08 Define rollback checkpoints**
  - Build: add a rollback note to `docs/architecture/rust-engine.md`: phase branches should be mergeable independently, and later phases must not be used to fix broken earlier moves.
  - Verify: every phase below has a test gate.

- [x] **RA00.09 Capture performance baseline**
  - Build: record fixture read API baseline and current indexed real-vault read UI baseline before code moves.
  - Verify: use budgets from `docs/benchmarks/read-api-ui-integration.md`; store only aggregate/redacted output.

- [x] **RA00.10 Capture indexing benchmark baseline**
  - Build: record backend benchmark stage timings, peak RSS, query p95/p99, writer memory budget, and time-to-usable samples before adapter/use-case moves.
  - Verify: compare against `docs/benchmarks/vault-indexing-performance.md`; treat current peak RSS as a no-worse gate, not as passing the target.

- [x] **RA00.11 Capture ABI layout manifest**
  - Build: record current `engine_*` symbols plus Rust-side `size_of`, `align_of`, field offsets, row-kind constants, state codes, and error-code strings for every Swift-decoded FFI struct.
  - Verify: manifest is generated from tests or a fixture command, not manually typed.

### Phase 1: Split FFI Without Behavior Changes

- [x] **RA01.00 Add FFI split checklist**
  - Build: add a temporary checklist in `vault-engine/src/ffi/mod.rs` comments or `docs/architecture/rust-engine.md` listing each helper group being moved.
  - Verify: checklist maps to RA01.01 through RA01.09.

- [x] **RA01.01 Convert `ffi.rs` to a directory module**
  - Build: move `vault-engine/src/ffi.rs` to `vault-engine/src/ffi/mod.rs`.
  - Verify: `cargo test --manifest-path vault-engine/Cargo.toml ffi::`.

- [x] **RA01.02 Extract FFI panic helpers**
  - Build: move panic hook lock and unwind helper logic into `vault-engine/src/ffi/panic.rs`.
  - Verify: existing panic-boundary tests still pass, and no panic helper is duplicated in read/save/graph FFI modules.

- [ ] **RA01.03 Extract C string and byte decoding helpers**
  - Build: move `read_c_string`, `read_read_string`, `read_rebuild_c_string`, and `read_bytes` style helpers into `vault-engine/src/ffi/strings.rs`.
  - Verify: invalid pointer/null/UTF-8 tests still return structured errors.

- [ ] **RA01.04 Extract JSON response envelope helpers**
  - Build: move `FfiResponse`, `FfiError`, JSON parse helpers, and `ffi_response` helpers into `vault-engine/src/ffi/json.rs` or `ffi/save.rs` if only save/graph uses them.
  - Verify: save baseline, save write, conflict choice, and whole-vault graph JSON tests still pass.

- [ ] **RA01.04a Keep JSON envelope names stable**
  - Build: preserve serialized field names `ok`, `value`, `error`, `code`, and `message`.
  - Verify: existing JSON assertions pass without snapshot updates except module path changes.

- [ ] **RA01.05 Extract read open and rebuild response helpers**
  - Build: move `read_open_response`, `read_rebuild_response`, and rebuild-specific error conversion into `vault-engine/src/ffi/read.rs`.
  - Verify: read open and rebuild FFI tests still pass.

- [ ] **RA01.05a Extract read page buffer helpers**
  - Build: move `read_page_response`, `read_items_buffer`, graph result buffer helpers, and read generation helpers into `vault-engine/src/ffi/read.rs`.
  - Verify: file tree, search, inspector, local graph, and live preview metadata FFI tests still pass.

- [ ] **RA01.05b Extract read error/state mapping**
  - Build: move `read_api_error_buffer`, `read_api_error_payload`, and read state code mapping into `vault-engine/src/ffi/read.rs`.
  - Verify: read error tests preserve existing error codes and state values.

- [ ] **RA01.06 Extract health functions**
  - Build: move `engine_abi_version` and `engine_health_check` into `vault-engine/src/ffi/health.rs`.
  - Verify: `swift run --package-path mac-app Granite --engine-smoke-test`.

- [ ] **RA01.06a Extract memory/free lifecycle functions**
  - Build: move `engine_string_free`, `engine_read_close`, and `engine_read_result_free` into the smallest appropriate FFI lifecycle module.
  - Verify: null-safe free/close tests still pass.

- [ ] **RA01.07 Extract save FFI functions**
  - Build: move save extern functions and save-specific FFI structs into `vault-engine/src/ffi/save.rs`.
  - Verify: save FFI unit tests pass and conflict payload JSON remains unchanged.

- [ ] **RA01.08 Extract whole-vault graph FFI functions**
  - Build: move graph request/payload conversion and graph extern function into `vault-engine/src/ffi/graph.rs`.
  - Verify: graph FFI tests pass and no graph membership code moves into FFI.

- [ ] **RA01.09 Keep module compatibility during transition**
  - Build: keep `crate::ffi` as the public module path and avoid changing C symbols.
  - Verify: `cargo build --manifest-path vault-engine/Cargo.toml --release` and compare `engine_*` symbol list to RA00.05.

- [ ] **RA01.10 Run FFI import boundary scan**
  - Build: no code change after RA01.09.
  - Verify: C string and `extern "C"` usage is confined to `vault-engine/src/ffi`.

- [ ] **RA01.11 Add FFI boundary regression tests**
  - Build: cover null C strings for every entry point, invalid UTF-8, null bytes pointer with `len > 0`, null bytes pointer with `len == 0`, null read handle for each read function, null `engine_string_free`, null `engine_read_close`, null `engine_read_result_free`, and panic conversion for save JSON, read buffer, and local graph dual-buffer paths.
  - Verify: invalid inputs return structured errors or no-op frees; no test aborts the process.

### Phase 2: Move Read ABI Rows Under FFI

- [ ] **RA02.01 Move read row layout code**
  - Build: move `vault-engine/src/read_ffi.rs` to `vault-engine/src/ffi/read_rows.rs`.
  - Verify: ABI layout fixture test still passes.

- [ ] **RA02.02 Add temporary compatibility re-export**
  - Build: if existing modules still import `crate::read_ffi`, keep a temporary `read_ffi` compatibility module that re-exports `ffi::read_rows` for one phase only.
  - Verify: no Swift-facing behavior changes.

- [ ] **RA02.03 Update imports to the new FFI row path**
  - Build: change Rust imports from `crate::read_ffi::*` to `crate::ffi::read_rows::*`.
  - Verify: `rg "crate::read_ffi" vault-engine/src` returns only the temporary compatibility module, or no matches if removed.

- [ ] **RA02.04 Remove compatibility module**
  - Build: delete temporary `read_ffi` re-export if no longer needed.
  - Verify: `cargo test --manifest-path vault-engine/Cargo.toml`.

- [ ] **RA02.05 Re-run ABI symbol and layout gate**
  - Build: no code change after RA02.04.
  - Verify: exported `engine_*` symbols match RA00.05, and ABI layout manifest from RA00.11 is unchanged.

### Phase 3: Extract Core Domain Records

- [ ] **RA03.01 Create `core` module skeleton**
  - Build: add `vault-engine/src/core/mod.rs`.
  - Verify: no public behavior changes; `cargo test` passes.

- [ ] **RA03.01a Add core import purity test script note**
  - Build: document the `rg` import purity command in `docs/architecture/rust-engine.md` before moving records.
  - Verify: the command initially returns no matches for the empty/new `core` module.

- [ ] **RA03.01b Move pure path and file identity primitives**
  - Build: move path/file identity value types that do not open or canonicalize filesystem paths into `core/paths.rs` or `core/files.rs`.
  - Verify: core denylist scan passes; path safety tests still pass through existing adapter code.

- [ ] **RA03.01c Move filesystem resolution out of path domain**
  - Build: classify `VaultRoot::open`, canonicalization, symlink checks, `FileIdentity::from_metadata`, and metadata extension usage as Phase 4 adapter moves in `docs/architecture/rust-engine.md`.
  - Verify: no filesystem resolution code is moved into `core`.

- [ ] **RA03.01d Move scan records and pure file classification**
  - Build: move `ScanEntryKind`, `ScanEntry`, `ScanSummary`, and pure `classify_file` into `core/scan.rs` or `core/files.rs`.
  - Verify: scanner tests pass and filesystem walking stays outside `core`.

- [ ] **RA03.01e Move parser output and property value types**
  - Build: move parser output structs/enums and property value types before metadata conversion moves.
  - Verify: parser fixture tests and metadata property tests still pass.

- [ ] **RA03.01f Move attachment domain enums**
  - Build: move attachment reference source/state/settings enums that are stored by metadata records into `core/attachments.rs`.
  - Verify: attachment resolution tests and metadata attachment tests pass.

- [ ] **RA03.01g Move link-key normalization**
  - Build: move `graph_key::unresolved_target_key` into `core/links.rs` before graph/read/sqlite users are moved.
  - Verify: graph and link resolution tests pass.

- [ ] **RA03.01h Move shared search DTOs**
  - Build: move stable search document/result DTOs out of `sqlite_fts.rs`; `tantivy_search` must not depend on the SQLite FTS module.
  - Verify: SQLite FTS and Tantivy search tests both pass.

- [ ] **RA03.02 Move metadata record structs**
  - Build: move only pure record types already used outside `index.rs` into `core/metadata.rs`: schema metadata, file records, link records, tag records, property records, heading records, and attachment records.
  - Verify: metadata store tests still pass.

- [ ] **RA03.02a Defer projection moves unless needed**
  - Build: keep SQL/projection types in the SQLite adapter until a non-SQL caller needs them outside storage.
  - Verify: no projection type is moved merely to satisfy the target tree.

- [ ] **RA03.02b Keep SQL-facing projection decision explicit**
  - Build: for each projection type moved to `core`, record whether it is domain-facing or storage-facing in `docs/architecture/rust-engine.md`.
  - Verify: SQL row decoding remains outside `core`.

- [ ] **RA03.03 Move metadata value conversion that is domain-only**
  - Build: move display/value methods that do not require rusqlite into `core/metadata.rs`.
  - Verify: property display tests still pass.

- [ ] **RA03.04 Keep SQL row decoders in SQLite adapter**
  - Build: leave `row_to_*`, `*_to_storage`, and `*_from_storage` helpers in the storage layer until Phase 4.
  - Verify: no `rusqlite` imports appear in `core/metadata.rs`.

- [ ] **RA03.05 Move graph domain structs**
  - Build: move graph request/node/edge/snapshot domain structs from `graph.rs` into `core/graph.rs` if they have no storage dependency.
  - Verify: graph unit tests still pass.

- [ ] **RA03.06 Move parsed document domain types**
  - Build: move parser output structs/enums that are pure domain types into `core/document.rs`, while leaving parsing implementation in place until a later phase.
  - Verify: parser fixture tests pass.

- [ ] **RA03.07 Move path value types only where safe**
  - Build: move pure path identity/value types into `core/paths.rs` only if they do not perform filesystem resolution.
  - Verify: `core` does not import `std::fs`.

- [ ] **RA03.08 Run core purity scan**
  - Build: no code change after RA03.07.
  - Verify:
    ```sh
    rg -n "std::fs|canonicalize|symlink_metadata|MetadataExt|OpenOptions|rename|remove_dir_all|rusqlite|tantivy|libc|FSEvent|extern \"C\"|unsafe|CStr|CString|no_mangle" vault-engine/src/core
    ```
    returns no matches.

### Phase 4: Extract Storage And Platform Adapters

- [ ] **RA04.01 Create adapter module skeleton**
  - Build: add `vault-engine/src/adapters/mod.rs`, `sqlite/mod.rs`, `tantivy/mod.rs`, and `fs/mod.rs`.
  - Verify: no behavior changes.

- [ ] **RA04.01a Move filesystem path resolver**
  - Build: move `VaultRoot::open`, canonicalization, symlink checks, `FileIdentity::from_metadata`, and metadata extension usage into `adapters/fs/path_resolver.rs`.
  - Verify: save path safety, scanner, startup reconciliation, and rebuild path tests still pass.

- [ ] **RA04.01b Move filesystem note writer**
  - Build: move temp write, permission preservation, atomic replacement, and mutation-time path revalidation into `adapters/fs/note_writer.rs` without changing save semantics.
  - Verify: save safety tests and FFI conflict choice tests pass.

- [ ] **RA04.01c Move index directory operations**
  - Build: move rebuild directory validation, swap, abort cleanup, and destructive directory operations into `adapters/fs/index_directory.rs`.
  - Verify: rebuild path safety and sentinel vault note tests pass.

- [ ] **RA04.02 Move SQLite metadata store mechanically**
  - Build: move the current `index.rs` storage implementation to `adapters/sqlite/metadata_store.rs` with minimal import fixes.
  - Verify: metadata store tests pass.

- [ ] **RA04.02a Keep SQLite schema diff empty**
  - Build: move SQL strings without editing schema text or index names.
  - Verify: metadata schema tests pass without expected value changes.

- [ ] **RA04.02b Split SQLite schema helpers only after mechanical move**
  - Build: if needed, split schema creation/index creation helpers inside the SQLite adapter after RA04.02 is green.
  - Verify: schema and projection index tests pass.

- [ ] **RA04.02c Split SQLite query groups only after schema helpers**
  - Build: if needed, group file tree, graph, links, properties, headings, and attachments queries inside the SQLite adapter without changing SQL text.
  - Verify: projection, graph query, and bounded query tests pass.

- [ ] **RA04.03 Keep metadata facade for use cases**
  - Build: expose a crate-internal `MetadataStore` path from `adapters::sqlite` and update imports.
  - Verify: `rg "crate::index::MetadataStore" vault-engine/src` trends to zero.

- [ ] **RA04.04 Move indexing queue store**
  - Build: move `indexing_queue.rs` to `adapters/sqlite/indexing_queue.rs`.
  - Verify: queue restart, lease, retry, cancel, and coalescing tests pass.

- [ ] **RA04.05 Move Tantivy search adapter**
  - Build: move `tantivy_search.rs` to `adapters/tantivy/search_index.rs`.
  - Verify: search query sanitization and indexing/search tests pass.

- [ ] **RA04.05a Keep Tantivy config stable**
  - Build: preserve tokenizer config, schema fields, writer options, snippet mode behavior, and error mapping.
  - Verify: search tests pass without changing expected snippets, scores, or error states.

- [ ] **RA04.06 Move filesystem scanner**
  - Build: move `scanner.rs` to `adapters/fs/scanner.rs`.
  - Verify: scanner fixture tests pass and core does not import scanner.

- [ ] **RA04.07 Move file watcher adapter**
  - Build: move `file_watcher.rs` to `adapters/fs/watcher.rs` or `adapters/fsevents/watcher.rs` depending on final naming.
  - Verify: watcher tests pass on macOS.

- [ ] **RA04.08 Move path resolution that touches disk**
  - Build: keep disk-canonicalization and vault root opening in an adapter path if it imports filesystem APIs.
  - Verify: save path safety and scanner tests pass.

- [ ] **RA04.09 Run adapter boundary scan**
  - Build: no code change after RA04.08.
  - Verify: adapters do not import `crate::ffi`, and Tantivy/SQLite adapters do not import each other's private modules.

- [ ] **RA04.10 Add rebuild adversarial path tests**
  - Build: cover `index_root` inside vault, `data_directory`/`rebuild_directory` outside index root, `data == rebuild`, symlinked data/rebuild/previous-data paths pointing into the vault, and failed commit/abort/reset paths.
  - Verify: a sentinel vault note remains unchanged after each rejected destructive operation.

### Phase 5: Extract Use Cases

- [ ] **RA05.01 Create use-case module skeleton**
  - Build: add `vault-engine/src/use_cases/mod.rs`.
  - Verify: no behavior changes.

- [ ] **RA05.02 Move `VaultReadApi` shell**
  - Build: move `VaultReadApi` type, constructor, generation getter, and open lifecycle into `use_cases/read_vault.rs`.
  - Verify: Rust read API constructor/open tests and Swift engine smoke pass.

- [ ] **RA05.02a Keep read state semantics stable**
  - Build: preserve `complete`, `partial`, `stale`, `cancelled`, `error`, and `index_unavailable` mapping.
  - Verify: read FFI tests and Swift read UI probe still interpret states correctly.

- [ ] **RA05.02b Move file tree and search read methods**
  - Build: move file tree, file-open metadata, file-name search, body search, and search mode dispatch into `use_cases/read_vault.rs`.
  - Verify: file tree and search FFI tests pass.

- [ ] **RA05.02c Move inspector panel read methods**
  - Build: move backlinks, outgoing links, tags, properties, headings, and attachments read methods.
  - Verify: inspector panel FFI tests pass.

- [ ] **RA05.02d Move local graph read methods**
  - Build: move local graph read orchestration while keeping graph construction owned by the graph use case if already extracted.
  - Verify: local graph FFI tests pass.

- [ ] **RA05.03 Split live preview metadata use case**
  - Build: move current-buffer link/tag/attachment metadata resolution into `use_cases/live_preview_metadata.rs`.
  - Verify: `engine_read_live_preview_metadata_uses_buffer_without_vault_scan` still passes.

- [ ] **RA05.04 Move save use case**
  - Build: move safe save orchestration from `save.rs` to `use_cases/save_note.rs`, keeping file write primitives in adapter/core as appropriate.
  - Verify: save safety and conflict choice tests pass.

- [ ] **RA05.05 Move index rebuild use case**
  - Build: move rebuild start/open/commit/abort orchestration into `use_cases/index_rebuild.rs`.
  - Verify: rebuild path safety and recovery tests pass.

- [ ] **RA05.06 Move indexing queue processing use case**
  - Build: move `process_indexing_queue_batch`, rebuild pipeline orchestration, and progress types into `use_cases/process_indexing_queue.rs`.
  - Verify: queue batch and full rebuild tests pass.

- [ ] **RA05.07 Move startup reconciliation use case**
  - Build: move startup reconciliation orchestration into `use_cases/reconcile_startup.rs`.
  - Verify: startup reconciliation tests pass.

- [ ] **RA05.08 Move watcher burst recovery use case**
  - Build: move watcher burst coalescing/recovery into `use_cases/watcher_burst.rs`.
  - Verify: watcher burst tests pass.

- [ ] **RA05.09 Move whole-vault/local graph use case**
  - Build: keep pure graph model in core and move snapshot construction/orchestration into `use_cases/build_graph.rs`.
  - Verify: local graph, whole-vault graph, and graph benchmark fixture tests pass.

- [ ] **RA05.10 Run use-case boundary scan**
  - Build: no code change after RA05.09.
  - Verify: use cases do not import `libc`, `CStr`, `CString`, `no_mangle`, or read result buffer row structs.

- [ ] **RA05.11 Re-run save path safety through moved use case**
  - Build: no behavior change after save use-case move.
  - Verify: preserve tests for external delete/edit/replace, symlink swap, new-note symlink parent, non-regular files, read-only targets, unsafe relative paths, and FFI conflict choices.

### Phase 6: Diagnostics, Benchmarks, And Profiler Boundary

- [ ] **RA06.01 Move benchmark code under diagnostics**
  - Build: move `benchmarks.rs` to `diagnostics/benchmarks.rs`.
  - Verify: benchmark tests and any benchmark CLI/probe imports compile.

- [ ] **RA06.02 Preserve aggregate-only privacy rules**
  - Build: ensure moved benchmark code still redacts raw note text, snippets, tags, query strings, and private paths.
  - Verify: benchmark artifact tests pass.

- [ ] **RA06.03 Run fixture read/index benchmark smoke**
  - Build: run existing fixture benchmark or profiler command if available in the repo.
  - Verify: produced artifact remains aggregate-only and no private vault content is committed.

- [ ] **RA06.04 Keep diagnostics out of production use cases**
  - Build: ensure production modules do not import `diagnostics`.
  - Verify: `rg "crate::diagnostics" vault-engine/src/core vault-engine/src/use_cases vault-engine/src/adapters vault-engine/src/ffi` returns no matches.

- [ ] **RA06.05 Add privacy scan gate**
  - Build: after generated benchmark/probe artifacts, scan only new or modified artifacts for private-path and content tokens before commit.
  - Verify: private payload outputs are ignored and opt-in; committed artifacts remain aggregate-only.

- [ ] **RA06.06 Migrate `bench/vault-profiler` imports**
  - Build: update profiler imports away from old public modules such as `benchmarks`, `tantivy_search`, `sqlite_fts`, `attachments`, `index`, `parser`, `paths`, `scanner`, and `read_api`.
  - Verify: `cargo test --manifest-path bench/vault-profiler/Cargo.toml`.

- [ ] **RA06.07 Decide SQLite FTS ownership**
  - Build: document and implement whether SQLite FTS remains a production adapter under `adapters/sqlite/fts_index.rs` or becomes diagnostics-only under `diagnostics/sqlite_fts.rs`.
  - Verify: profiler and search benchmark tests pass after the decision.

### Phase 7: Reduce Public Surface

- [ ] **RA07.01 Rewrite `lib.rs` module exports**
  - Build: expose `pub mod ffi` and intentional public facades only; make internals `pub(crate)` where possible.
  - Verify: Rust tests compile without relying on unintended public modules.

- [ ] **RA07.01a Reduce public surface in two passes**
  - Build: first change `pub mod` to `pub(crate) mod` only for modules with no external Rust consumers. Then remove transitional modules in a separate step.
  - Verify: each pass compiles independently.

- [ ] **RA07.02 Update health check module list**
  - Build: update `health_check()` to report architecture-level modules or intentional engine capabilities, not every internal file.
  - Verify: health check unit test and Swift engine smoke pass.

- [ ] **RA07.03 Remove transitional re-exports**
  - Build: delete compatibility modules added only for incremental migration.
  - Verify: `rg "read_ffi|crate::index::MetadataStore|crate::tantivy_search|crate::indexing_queue" vault-engine/src` returns only intentional references or none.

- [ ] **RA07.04 Add architecture placement checklist**
  - Build: add a short checklist to `docs/architecture/rust-engine.md` explaining where new parser, storage, FFI, and use-case code should go.
  - Verify: checklist covers future work for read API, save, graph, indexing, watcher, benchmarks, and profiler imports.

- [ ] **RA07.05 Run public API grep**
  - Build: no code change after RA07.04.
  - Verify: inspect remaining `pub mod` and `pub use` entries in `vault-engine/src/lib.rs`; each has a documented reason.

## Verification Plan

### Per-Task Gate

Run after each small implementation task:

```sh
cargo test --manifest-path vault-engine/Cargo.toml
```

If a task changes formatting or module paths:

```sh
cargo fmt --manifest-path vault-engine/Cargo.toml --check
```

### FFI Gate

Run after Phase 1 and Phase 2:

```sh
cargo build --manifest-path vault-engine/Cargo.toml --release
swift run --package-path mac-app Granite --engine-smoke-test
```

Also compare exported `engine_*` symbols against the RA00.05 baseline.

ABI symbol comparison command:

```sh
nm -gU vault-engine/target/release/libvault_engine.dylib | awk '{print $3}' | grep '^_engine_' | sort
```

### Swift Integration Gate

Run after Phase 5 and Phase 7:

```sh
swift test --package-path mac-app
swift run --package-path mac-app Granite --engine-smoke-test
swift run --package-path mac-app Granite --read-api-ui-probe
```

If the read API probe requires a prepared fixture or local vault, run the fixture path first and keep private-vault artifacts out of Git.

### Package Gate

Run before merging:

```sh
./scripts/package-macos-app.sh
codesign --verify --deep --strict dist/Granite.app
dist/Granite.app/Contents/MacOS/Granite --engine-smoke-test
dist/Granite.app/Contents/MacOS/Granite --live-preview-style-probe
dist/Granite.app/Contents/MacOS/Granite --editor-bridge-probe
```

### Real-Vault Regression Gate

Run only after automated fixture gates pass:

```sh
swift run --package-path mac-app Granite --read-api-ui-probe --vault "/Users/heeung/Documents/Codex Vault"
```

Expected:

- Inspector visible tab p95 `<= 1s`, p99 `<= 3s` on indexed vault.
- Search first page p95 `<= 1s`, p99 `<= 3s` on indexed vault.
- No raw note text, snippets, tag values, query strings, or full private paths in committed artifacts.

### Backend Performance Gate

Run after Phase 4 and Phase 5:

- Fixture `backend-benchmark`.
- Fixture or real `read-api-benchmark`.
- Real-vault read UI probe after fixture gates pass.

Before merge, run real-vault backend benchmark with at least `--time-to-usable-samples 3` if the command supports it.

Block the refactor if any apply:

- Full metadata + Tantivy usable time regresses by `> 10%` from RA00.10 baseline.
- Peak RSS regresses by `> 5%` from RA00.10 baseline. Current documented RSS already misses the target, so this is a no-worse gate.
- Tantivy add, SQLite metadata write, or Tantivy commit regresses by `> 10%`.
- Search p95/p99 regresses by `> 20%`.
- Read UI p95/p99 exceeds documented targets.
- Benchmark artifacts lose `peak_rss_bytes`, `time_to_usable_samples`, stage timing, writer memory budget, or aggregate-only privacy fields.

### Architecture Boundary Gate

Run after Phases 3, 4, 5, 6, and 7:

```sh
rg -n "std::fs|canonicalize|symlink_metadata|MetadataExt|OpenOptions|rename|remove_dir_all|rusqlite|tantivy|libc|FSEvent|extern \"C\"|unsafe|CStr|CString|no_mangle" vault-engine/src/core
rg -n "CStr|CString|c_char|c_uchar|no_mangle|extern \"C\"" vault-engine/src/use_cases vault-engine/src/adapters
rg -n "crate::ffi" vault-engine/src/core vault-engine/src/use_cases vault-engine/src/adapters
rg -n "crate::diagnostics" vault-engine/src/core vault-engine/src/use_cases vault-engine/src/adapters vault-engine/src/ffi
```

Any match must be either removed or documented as an explicit exception in `docs/architecture/rust-engine.md`.

### Rollback Gate

At the end of each phase:

- Each RA task should be independently revertible.
- Prefer one commit per RA task during implementation.
- For file moves, first commit the mechanical move with minimal import fixes.
- If tests fail after a semantic extraction, revert only the latest extraction commit, not the whole phase.
- Keep temporary compatibility re-exports until all callers are migrated and verified.
- Remove compatibility shims in a separate final cleanup commit.
- Working tree should contain only that phase's intended files.
- Rust tests must pass.
- If ABI-sensitive, symbol list must match baseline.
- If the phase cannot pass without behavior changes, stop and revise the plan before continuing.

## Acceptance Criteria

### Architecture

- [ ] `vault-engine` has explicit `core`, `use_cases`, `adapters`, `ffi`, and `diagnostics` module areas.
- [ ] `core` does not import `rusqlite`, `tantivy`, `libc`, FSEvents APIs, or filesystem crawling APIs.
- [ ] `ffi` contains C ABI, buffer ownership, string decoding, panic containment, and conversion code only.
- [ ] Use cases own orchestration and do not expose adapter internals to Swift.
- [ ] SQLite, Tantivy, filesystem scanning, and file watching live under adapters.
- [ ] `lib.rs` no longer publicly exposes every internal module.
- [ ] `docs/architecture/rust-engine.md` documents placement rules.
- [ ] Architecture doc maps every current module, including `attachments`, `parser`, `paths`, `sqlite_fts`, `graph_key`, `errors`, and `bench/vault-profiler` imports.
- [ ] Import guard proves no reverse dependencies: core has no adapters/use_cases/ffi/diagnostics; adapters have no ffi/use_cases/diagnostics; use cases have no ffi/diagnostics/direct storage/platform crates.
- [ ] Final `ffi` imports no `MetadataStore`, `IndexingQueue`, `TantivySearchIndex`, `IndexRebuildPaths`, scanner, parser, or SQL/Tantivy types except through approved handle wiring.
- [ ] Import boundary scans pass or documented exceptions are explicit and narrow.
- [ ] Mechanical moves and semantic extractions are separated in the implementation history.
- [ ] Unsafe/FFI grep output matches the approved allowlist; no unsafe FFI helpers drift into `core` or `use_cases`.
- [ ] `core` denylist gate passes.
- [ ] `lib.rs` exposes only intentional public facades, including a deliberate diagnostics/profiler facade if `bench/vault-profiler` remains a separate crate.

### Compatibility

- [ ] All exported C symbol names used by Swift remain available.
- [ ] Read result row layouts remain ABI-compatible.
- [ ] Save JSON envelopes remain compatible.
- [ ] Read error codes and states remain compatible.
- [ ] Packaged `Granite.app` still bundles and loads `libvault_engine.dylib`.
- [ ] Exported `engine_*` symbols match the pre-refactor baseline.
- [ ] ABI layout manifest is unchanged after Phases 1, 2, 5, and 6.
- [ ] All FFI invalid-input and panic tests return structured errors without aborting.

### Quality

- [ ] Rust tests pass.
- [ ] Swift tests pass.
- [ ] `cargo test --manifest-path bench/vault-profiler/Cargo.toml` passes before public-surface cleanup is accepted.
- [ ] Engine smoke test passes.
- [ ] Read API UI probe passes on fixture.
- [ ] Package script passes.
- [ ] No private vault content is committed.
- [ ] No behavior-changing optimization or schema migration is bundled into the refactor.
- [ ] No new adapter trait exists unless the plan or implementation documents the concrete test seam it enables.
- [ ] No production module depends on `diagnostics`.
- [ ] Destructive path tests prove failed save/rebuild operations do not mutate vault sentinel files.
- [ ] New or modified diagnostics artifacts pass the privacy scan.
- [ ] SQLite/Tantivy/search adapter moves do not introduce string-built SQL from user input; query sanitization tests still pass.
- [ ] Hot-path no-allocation rules are preserved or exceptions are benchmarked and documented.
- [ ] Graph refactor preserves graph snapshot privacy and bridge gates from `docs/architecture/graph-view.md`, not only unit tests.

## Dependencies And Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Large file moves obscure behavior changes | Review becomes difficult | Use mechanical move commits first, then extraction commits |
| C ABI symbols change accidentally | Swift app fails at runtime | Compare exported `engine_*` symbols after FFI phases |
| Read row layout changes accidentally | Swift decode corruption | Keep layout fixture tests and packaged engine smoke gate |
| `core` becomes impure | Architecture erodes quickly | Add doc checklist and import review for `rusqlite`, `tantivy`, `libc`, filesystem |
| Trait abstraction overreach | More complexity without value | Prefer concrete adapters first; add traits only where tests need seams |
| Performance hot path allocations increase | Large vault regressions | Run read API UI probe and existing benchmark smoke after structural phases |
| `use_cases` becomes a dumping ground | Same problem under new name | Keep one use-case file per user/system workflow and document ownership |
| Circular dependencies appear during extraction | Refactor stalls or encourages bad re-exports | Move pure records before adapters; use temporary compatibility re-exports only for one phase |
| Public API shrinks too early | Tests and downstream Swift build break while moving code | Delay `lib.rs` cleanup until Phase 7 |
| Diagnostics leak into production modules | Benchmark/privacy code affects runtime behavior | Add `crate::diagnostics` import scan |
| Rollback becomes difficult after mixed edits | Hard to isolate regression | Keep each task to move-only or extraction-only and stop at failed phase gates |
| Adapter facades hide unbounded materialization | Memory and latency regressions in large vaults | Add no-allocation rules and backend performance gate |
| Search adapter recreates query/index/searcher state per request | Search p95/p99 regress | Preserve existing Tantivy lifecycle and read API benchmarks |
| Use-case extraction adds extra scan/read/parse pass | Full rebuild and queue processing regress | Keep streaming rebuild and queue lease limits intact |
| FFI layout changes without symbol changes | Swift decodes corrupted buffers | Add ABI layout manifest, not only symbol comparison |
| Path validation moves away from mutation sites | Save/rebuild can mutate outside allowed roots | Re-run adversarial path and sentinel tests after use-case moves |
| Public surface cleanup breaks `bench/vault-profiler` | Benchmarks no longer compile after internal modules become private | Migrate profiler imports in Phase 6 before reducing exports in Phase 7 |
| DTOs move to the wrong layer | FFI/diagnostics serialization leaks into core | Keep FFI JSON DTOs in `ffi` and benchmark artifact DTOs in `diagnostics` |

## Migration Order Rationale

1. FFI is split first because it is the largest coupling point and can be moved without changing business behavior.
2. Read ABI rows move next because they are FFI-owned by nature and have stable layout tests.
3. Core records move before adapters so storage code can depend on stable domain types.
4. Storage/platform adapters move before use cases so orchestration can be expressed against clearer dependencies.
5. Public surface cleanup happens last because early cleanup would force too many compatibility shims.

## Implementation Review Checklist

Use this checklist for each PR or worktree batch:

- [ ] Does this batch contain only one phase or a clearly contiguous subset of a phase?
- [ ] Are file moves separated from semantic edits?
- [ ] Did any `#[repr(C)]` struct change? If yes, stop unless explicitly planned.
- [ ] Did any C symbol name change? If yes, stop unless explicitly planned.
- [ ] Did any SQLite schema/index/query text change? If yes, split it out of this refactor.
- [ ] Did any Tantivy schema/tokenizer/writer option change? If yes, split it out.
- [ ] Did `core` gain a storage, FFI, or filesystem import?
- [ ] Did production code start importing `diagnostics`?
- [ ] Are tests moved with their owning module, or intentionally kept as integration tests?
- [ ] Is any new trait justified by an immediate test seam?

## References

### Internal

- Brainstorm: `docs/brainstorms/2026-05-27-rust-engine-architecture-brainstorm.md`
- Engine boundary: `docs/architecture/engine-boundary.md`
- Save safety: `docs/architecture/save-safety.md`
- Graph ownership: `docs/architecture/graph-view.md`
- Read API integration benchmark: `docs/benchmarks/read-api-ui-integration.md`
- Indexing performance benchmark: `docs/benchmarks/vault-indexing-performance.md`
- Current Rust crate root: `vault-engine/src/lib.rs`
- Current FFI module: `vault-engine/src/ffi.rs`
- Current read row layout: `vault-engine/src/read_ffi.rs`
- Current metadata store: `vault-engine/src/index.rs`
- Current indexing pipeline: `vault-engine/src/indexing_pipeline.rs`
- Current benchmark/profiler consumer: `bench/vault-profiler/Cargo.toml`

### External

- [rust-analyzer architecture](https://rust-analyzer.github.io/book/contributing/architecture.html)
- [rust-analyzer project_model](https://rust-lang.github.io/rust-analyzer/project_model/index.html)
- [nu_protocol docs](https://docs.rs/nu-protocol/latest/nu_protocol/)
- [Tantivy docs](https://docs.rs/tantivy/latest/tantivy/)
- [Rust API Guidelines checklist](https://rust-lang.github.io/api-guidelines/checklist.html)
- [Rust Book modules/privacy](https://doc.rust-lang.org/book/ch07-02-defining-modules-to-control-scope-and-privacy.html)

## Next Step

Start implementation with Phase 0 and Phase 1 only. Do not start Phase 3+ until FFI split, ABI symbol comparison, and read row layout verification are green.
