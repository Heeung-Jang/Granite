---
title: "refactor: Introduce Layered Rust Engine Architecture"
type: refactor
date: 2026-05-27
deepened_on: 2026-05-27
deepened_passes: 7
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

This deepening adds seven specialist review passes and tightens the original plan around architecture, simplicity, performance, security risks, and implementation granularity:

- Separate **mechanical moves** from **semantic extraction**. A task should either move code without changing behavior or extract a boundary with new verification, not both.
- Add explicit **import boundary checks** so the new `core`, `ffi`, `adapters`, and `use_cases` names cannot drift immediately after the refactor.
- Add an **ABI symbol gate** before and after the FFI split, because Swift loads C symbols at runtime.
- Keep **rollback points** at phase boundaries. If a phase fails, the next phase should not start until the current phase is green.
- Keep **adapter traits deferred**. The architecture should be enforced by modules first, not by speculative traits.
- Add a fifth pass focused on **implementation micro-units**. Large moves such as SQLite metadata storage and `VaultReadApi` extraction are now broken into helper groups, method groups, and explicit verification gates.
- Add a sixth pass focused on **post-adapter performance gates, FFI retargeting, unsafe allowlists, path safety, SQL construction, and diagnostics privacy**.
- Add a seventh pass focused on **remaining-phase micro-units**. Startup reconciliation, watcher burst recovery, graph use-case extraction, diagnostics/profiler migration, and public-surface cleanup now have smaller, independently verifiable tasks.

### Section Manifest

| Section | Deepening Focus |
| --- | --- |
| Proposed Architecture | Add layer invariants and import rules that can be checked with `rg`. |
| Implementation Phases | Split broad moves into compile-safe, reviewable units with phase gates. |
| Verification Plan | Add ABI symbol comparison, architecture import scans, and privacy/performance gates. |
| Risks | Add rollback, circular dependency, and accidental public API risks. |
| Acceptance Criteria | Add measurable layer purity and compatibility criteria. |
| Implementation Micro-Units | Split high-risk storage/use-case moves into small, independently verifiable tasks. |
| Pass 6 Corrections | Add explicit FFI retarget tasks, performance gates, unsafe/path/SQL/privacy allowlists, and stale next-step correction. |
| Pass 7 Remaining Phases | Split RA05.07-RA07 into concrete move, retarget, facade, privacy, and cleanup gates. |

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

### Pass 7 References

- Rust Reference visibility rules support using private modules plus `pub(crate)`/re-exports to keep internal facades available in-crate while reducing external API exposure: [Visibility and privacy](https://doc.rust-lang.org/reference/visibility-and-privacy.html).
- Rustonomicon FFI guidance reinforces keeping raw pointers, C ABI declarations, and safety invariants at the FFI boundary instead of leaking them into safe use cases: [Foreign Function Interface](https://doc.rust-lang.org/nomicon/ffi.html).
- Rust API Guidelines reinforce that public error types and public surfaces should be deliberate contracts, not accidental exposure from refactoring convenience: [Interoperability](https://rust-lang.github.io/api-guidelines/interoperability.html).

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
- Final-state FFI must not call legacy orchestration modules such as `read_api`, `save`, `graph`, `indexing_pipeline`, `index_rebuild`, `startup_reconciliation`, or `watcher_burst`. FFI decodes inputs, calls use cases, and encodes responses.
- Parser ownership must be explicit before Phase 5 closes: either pure Markdown parsing remains documented as a domain module or parser functions/types move under `core/document.rs` or `core/parser.rs`.

Recommended import checks after each phase:

```sh
rg -n "rusqlite|tantivy|libc|std::fs|fsevent|FSEvent" vault-engine/src/core
rg -n "std::fs|OpenOptions|rename|remove_dir_all|canonicalize|symlink_metadata|MetadataExt|rusqlite|tantivy|libc|FSEvent" vault-engine/src/use_cases
rg -n "unsafe|extern \"C\"|CStr|CString::from_raw|Vec::from_raw_parts|slice::from_raw_parts|no_mangle" vault-engine/src -g '!ffi/**' -g '!adapters/fsevents/watcher.rs' -g '!diagnostics/**'
rg -n "crate::ffi" vault-engine/src/core vault-engine/src/use_cases vault-engine/src/adapters
rg -n "crate::(read_api|save|graph|indexing_pipeline|index_rebuild|startup_reconciliation|watcher_burst|scanner|paths|parser|attachments|graph_key)" vault-engine/src/use_cases vault-engine/src/ffi vault-engine/src/adapters
rg -n "crate::adapters::(tantivy|fs|fsevents)" vault-engine/src/adapters/sqlite
rg -n "crate::adapters::(sqlite|fs|fsevents)" vault-engine/src/adapters/tantivy
rg -n "crate::adapters::(sqlite|tantivy)" vault-engine/src/adapters/fs vault-engine/src/adapters/fsevents
```

Expected result: no matches except explicit documented exceptions in `docs/architecture/rust-engine.md`.

### Safety Invariants

- FFI unsafe boundary: `#[unsafe(no_mangle)]`, `extern "C"`, raw pointer decoding, `CString::from_raw`, `Vec::from_raw_parts`, `CStr::from_ptr`, and `slice::from_raw_parts` stay confined to `ffi/**`, `adapters/fsevents/watcher.rs`, or diagnostics-only libc code. No raw pointer or FFI buffer type reaches `core` or `use_cases`.
- Unsafe discipline: every unsafe block must have a local safety comment. FSEvents callback code must prove callback context ownership, stream invalidation before context drop, no unwind across the C callback, and no use-after-free across stop/restart/drop.
- ABI layout: all `#[repr(C)]` read/result/save structs, row-kind constants, state codes, error codes, JSON envelope keys, field order, `size_of`, `align_of`, and field offsets are frozen unless the refactor explicitly declares an ABI migration.
- FFI ownership: Rust allocates returned strings/buffers and only the matching Rust free function releases them. Null free/close remains a no-op. Invalid null/UTF-8/byte inputs return structured errors. Panics never cross FFI.
- Path safety: write/delete/rename/link/rebuild operations only use `VaultRoot` plus normalized relative paths or validated `IndexRebuildPaths`. All containment checks must compare canonical `Path` components with `Path::starts_with`, never string prefixes. All destructive operations revalidate canonical parent/target immediately before mutation and reject absolute paths, traversal, URL schemes, tilde, NUL, symlink escapes, non-regular files, and vault/index overlap.
- Hardlink policy: if hardlinks are not explicitly supported, save/index/read filesystem adapters must reject regular files with link count `> 1` so content hardlinked from outside the vault is not silently indexed or exposed.
- Destructive operation safety: `remove_dir_all`, swaps, abort cleanup, and reset operations must require an engine-owned marker file inside the target index directory in addition to canonical containment.
- Database trust boundary: metadata DB contents are not trusted for filesystem mutation. Paths read from SQLite or JSON must be re-normalized as vault-relative values at the mutation boundary.
- Core purity: `core` may contain path value types, but not filesystem resolution, `FileIdentity::from_metadata`, canonicalization, `MetadataExt`, SQLite, Tantivy, FSEvents, or libc.
- Privacy: committed diagnostics/probe/benchmark artifacts remain aggregate-only. No note body, snippets, tags, frontmatter values, query strings, file IDs, raw relative paths, or full private paths. Redaction applies to normal fields, error strings, panic payloads, `Debug` output, benchmark/probe CLI args, and SQLite/Tantivy error messages. Private payloads must require an explicit private output path under an ignored directory.

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

Hot-path diff gate:

```sh
git diff --unified=0 -- vault-engine/src |
  rg -n '^\+.*(collect::<Vec|\.collect\(\)|\.clone\(\)|to_string\(\)|format!\(|serde_json::|Box<dyn|Arc<dyn|read_to_string|std::fs::read|Index::open_in_dir|reader\(\)|writer\(|commit\(|reload\()'
```

Expected: zero new matches in read/search/indexing/FFI graph hot paths, or a documented exception with benchmark evidence.

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

## Implementation Unit Contract

Every RA task should be small enough to review and revert alone:

- One task should change one cohesive helper group, one public module declaration group, or one method group.
- One task should normally touch `<= 3` production files, excluding moved tests and docs.
- A task that moves more than roughly `250` lines must be mechanical only: move code, fix imports, run tests, and stop.
- A task that changes behavior must not also move files.
- A task that changes visibility must not also rewrite logic.
- A task that changes FFI, row layouts, SQL text, Tantivy config, path validation, or benchmark output privacy must get its own gate task.
- If implementation needs a temporary re-export, add it in one task and remove it in a later cleanup task after all callers are migrated.

Each RA task must include:

```txt
Build: the exact file/module move or extraction.
Verify: the narrowest test or scan that proves the move did not change behavior.
Stop condition: the first signal that means the next RA task must not start.
```

Default stop conditions:

- `cargo test` or Swift smoke fails.
- ABI symbol/layout output differs outside an explicitly planned migration.
- `core` gains storage, platform, or FFI imports.
- SQL/Tantivy config text changes during a move-only task.
- A private-vault path or content token appears in a committed artifact.

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

- [x] **RA01.03 Extract C string and byte decoding helpers**
  - Build: move `read_c_string`, `read_read_string`, `read_rebuild_c_string`, and `read_bytes` style helpers into `vault-engine/src/ffi/strings.rs`.
  - Verify: invalid pointer/null/UTF-8 tests still return structured errors.

- [x] **RA01.04 Extract JSON response envelope helpers**
  - Build: move `FfiResponse`, `FfiError`, JSON parse helpers, and `ffi_response` helpers into `vault-engine/src/ffi/json.rs` or `ffi/save.rs` if only save/graph uses them.
  - Verify: save baseline, save write, conflict choice, and whole-vault graph JSON tests still pass.

- [x] **RA01.04a Keep JSON envelope names stable**
  - Build: preserve serialized field names `ok`, `value`, `error`, `code`, and `message`.
  - Verify: existing JSON assertions pass without snapshot updates except module path changes.

- [x] **RA01.05 Extract read open and rebuild response helpers**
  - Build: move `read_open_response`, `read_rebuild_response`, and rebuild-specific error conversion into `vault-engine/src/ffi/read.rs`.
  - Verify: read open and rebuild FFI tests still pass.

- [x] **RA01.05a Extract read page buffer helpers**
  - Build: move `read_page_response`, `read_items_buffer`, graph result buffer helpers, and read generation helpers into `vault-engine/src/ffi/read.rs`.
  - Verify: file tree, search, inspector, local graph, and live preview metadata FFI tests still pass.

- [x] **RA01.05b Extract read error/state mapping**
  - Build: move `read_api_error_buffer`, `read_api_error_payload`, and read state code mapping into `vault-engine/src/ffi/read.rs`.
  - Verify: read error tests preserve existing error codes and state values.

- [x] **RA01.06 Extract health functions**
  - Build: move `engine_abi_version` and `engine_health_check` into `vault-engine/src/ffi/health.rs`.
  - Verify: `swift run --package-path mac-app Granite --engine-smoke-test`.

- [x] **RA01.06a Extract memory/free lifecycle functions**
  - Build: move `engine_string_free`, `engine_read_close`, and `engine_read_result_free` into the smallest appropriate FFI lifecycle module.
  - Verify: null-safe free/close tests still pass.

- [x] **RA01.07 Extract save FFI functions**
  - Build: move save extern functions and save-specific FFI structs into `vault-engine/src/ffi/save.rs`.
  - Verify: save FFI unit tests pass and conflict payload JSON remains unchanged.

- [x] **RA01.08 Extract whole-vault graph FFI functions**
  - Build: move graph request/payload conversion and graph extern function into `vault-engine/src/ffi/graph.rs`.
  - Verify: graph FFI tests pass and no graph membership code moves into FFI.

- [x] **RA01.09 Keep module compatibility during transition**
  - Build: keep `crate::ffi` as the public module path and avoid changing C symbols.
  - Verify: `cargo build --manifest-path vault-engine/Cargo.toml --release` and compare `engine_*` symbol list to RA00.05.

- [x] **RA01.10 Run FFI import boundary scan**
  - Build: no code change after RA01.09.
  - Verify: C string and `extern "C"` usage is confined to `vault-engine/src/ffi`.

- [x] **RA01.11 Add FFI boundary regression tests**
  - Build: cover null C strings for every entry point, invalid UTF-8, null bytes pointer with `len > 0`, null bytes pointer with `len == 0`, null read handle for each read function, null `engine_string_free`, null `engine_read_close`, null `engine_read_result_free`, and panic conversion for save JSON, read buffer, and local graph dual-buffer paths.
  - Verify: invalid inputs return structured errors or no-op frees; no test aborts the process.

- [ ] **RA01.12 Audit unsafe allowlist**
  - Build: no behavior change; verify every unsafe block has a local safety comment, FFI entry points keep panic containment around fallible work, and unsafe operations remain inside the approved FFI/FSEvents/diagnostics allowlist.
  - Verify: unsafe grep returns only `ffi/**`, `adapters/fsevents/watcher.rs`, or diagnostics-only matches; FSEvents stop/restart/drop tests do not unwind or use freed callback context.

- [ ] **RA01.12a Enforce unsafe lint gate**
  - Build: no behavior change; run a lint-only gate after unsafe comments and allowlist ownership are checked.
  - Verify:
    ```sh
    cargo clippy --manifest-path vault-engine/Cargo.toml -- -D clippy::undocumented_unsafe_blocks -D unsafe_op_in_unsafe_fn
    ```
  - Stop condition: any unsafe block lacks a local safety comment, or any unsafe operation appears outside `ffi/**`, `adapters/fsevents/watcher.rs`, or diagnostics-only code.

### Phase 2: Move Read ABI Rows Under FFI

- [x] **RA02.01 Move read row layout code**
  - Build: move `vault-engine/src/read_ffi.rs` to `vault-engine/src/ffi/read_rows.rs`.
  - Verify: ABI layout fixture test still passes.

- [x] **RA02.02 Add temporary compatibility re-export**
  - Build: if existing modules still import `crate::read_ffi`, keep a temporary `read_ffi` compatibility module that re-exports `ffi::read_rows` for one phase only.
  - Verify: no Swift-facing behavior changes.

- [x] **RA02.03 Update imports to the new FFI row path**
  - Build: change Rust imports from `crate::read_ffi::*` to `crate::ffi::read_rows::*`.
  - Verify: `rg "crate::read_ffi" vault-engine/src` returns only the temporary compatibility module, or no matches if removed.

- [x] **RA02.04 Remove compatibility module**
  - Build: delete temporary `read_ffi` re-export if no longer needed.
  - Verify: `cargo test --manifest-path vault-engine/Cargo.toml`.

- [x] **RA02.05 Re-run ABI symbol and layout gate**
  - Build: no code change after RA02.04.
  - Verify: exported `engine_*` symbols match RA00.05, and ABI layout manifest from RA00.11 is unchanged.

### Phase 3: Extract Core Domain Records

- [x] **RA03.01 Create `core` module skeleton**
  - Build: add `vault-engine/src/core/mod.rs`.
  - Verify: no public behavior changes; `cargo test` passes.

- [x] **RA03.01a Add core import purity test script note**
  - Build: document the `rg` import purity command in `docs/architecture/rust-engine.md` before moving records.
  - Verify: the command initially returns no matches for the empty/new `core` module.

- [x] **RA03.01b Move pure path and file identity primitives**
  - Build: move path/file identity value types that do not open or canonicalize filesystem paths into `core/paths.rs` or `core/files.rs`.
  - Verify: core denylist scan passes; path safety tests still pass through existing adapter code.

- [x] **RA03.01c Move filesystem resolution out of path domain**
  - Build: classify `VaultRoot::open`, canonicalization, symlink checks, `FileIdentity::from_metadata`, and metadata extension usage as Phase 4 adapter moves in `docs/architecture/rust-engine.md`.
  - Verify: no filesystem resolution code is moved into `core`.

- [x] **RA03.01d Move scan records and pure file classification**
  - Build: move `ScanEntryKind`, `ScanEntry`, `ScanSummary`, and pure `classify_file` into `core/scan.rs` or `core/files.rs`.
  - Verify: scanner tests pass and filesystem walking stays outside `core`.

- [x] **RA03.01e Move parser output and property value types**
  - Build: move parser output structs/enums and property value types before metadata conversion moves.
  - Verify: parser fixture tests and metadata property tests still pass.

- [x] **RA03.01f Move attachment domain enums**
  - Build: move attachment reference source/state/settings enums that are stored by metadata records into `core/attachments.rs`.
  - Verify: attachment resolution tests and metadata attachment tests pass.

- [x] **RA03.01g Move link-key normalization**
  - Build: move `graph_key::unresolved_target_key` into `core/links.rs` before graph/read/sqlite users are moved.
  - Verify: graph and link resolution tests pass.

- [x] **RA03.01h Move shared search DTOs**
  - Build: move stable search document/result DTOs out of `sqlite_fts.rs`; `tantivy_search` must not depend on the SQLite FTS module.
  - Verify: SQLite FTS and Tantivy search tests both pass.

- [x] **RA03.02 Move metadata record structs**
  - Build: move only pure record types already used outside `index.rs` into `core/metadata.rs`: schema metadata, file records, link records, tag records, property records, heading records, and attachment records.
  - Verify: metadata store tests still pass.

- [x] **RA03.02a Defer projection moves unless needed**
  - Build: keep SQL/projection types in the SQLite adapter until a non-SQL caller needs them outside storage.
  - Verify: no projection type is moved merely to satisfy the target tree.

- [x] **RA03.02b Keep SQL-facing projection decision explicit**
  - Build: for each projection type moved to `core`, record whether it is domain-facing or storage-facing in `docs/architecture/rust-engine.md`.
  - Verify: SQL row decoding remains outside `core`.

- [x] **RA03.03 Move metadata value conversion that is domain-only**
  - Build: move display/value methods that do not require rusqlite into `core/metadata.rs`.
  - Verify: property display tests still pass.

- [x] **RA03.04 Keep SQL row decoders in SQLite adapter**
  - Build: leave `row_to_*`, `*_to_storage`, and `*_from_storage` helpers in the storage layer until Phase 4.
  - Verify: no `rusqlite` imports appear in `core/metadata.rs`.

- [x] **RA03.05 Move graph domain structs**
  - Build: move graph request/node/edge/snapshot domain structs from `graph.rs` into `core/graph.rs` if they have no storage dependency.
  - Verify: graph unit tests still pass.

- [x] **RA03.06 Move parsed document domain types**
  - Build: move parser output structs/enums that are pure domain types into `core/document.rs`, while leaving parsing implementation in place until a later phase.
  - Verify: parser fixture tests pass.

- [x] **RA03.07 Move path value types only where safe**
  - Build: move pure path identity/value types into `core/paths.rs` only if they do not perform filesystem resolution.
  - Verify: `core` does not import `std::fs`.

- [x] **RA03.08 Run core purity scan**
  - Build: no code change after RA03.07.
  - Verify:
    ```sh
    rg -n "std::fs|canonicalize|symlink_metadata|MetadataExt|OpenOptions|rename|remove_dir_all|rusqlite|tantivy|libc|FSEvent|extern \"C\"|unsafe|CStr|CString|no_mangle" vault-engine/src/core
    ```
    returns no matches.

### Phase 4: Extract Storage And Platform Adapters

- [x] **RA04.01 Create adapter module skeleton**
  - Build: add `vault-engine/src/adapters/mod.rs`, `sqlite/mod.rs`, `tantivy/mod.rs`, and `fs/mod.rs`.
  - Verify: no behavior changes.

- [x] **RA04.01a Move filesystem path resolver**
  - Build: move `VaultRoot::open`, canonicalization, symlink checks, `FileIdentity::from_metadata`, and metadata extension usage into `adapters/fs/path_resolver.rs`.
  - Verify: save path safety, scanner, startup reconciliation, and rebuild path tests still pass.

- [x] **RA04.01b Move filesystem note writer**
  - Build: move temp write, permission preservation, atomic replacement, and mutation-time path revalidation into `adapters/fs/note_writer.rs` without changing save semantics.
  - Verify: save safety tests and FFI conflict choice tests pass.

- [x] **RA04.01c Move index directory operations**
  - Build: move rebuild directory validation, swap, abort cleanup, and destructive directory operations into `adapters/fs/index_directory.rs`.
  - Verify: rebuild path safety and sentinel vault note tests pass.

- [x] **RA04.02 Add SQLite adapter facade without moving storage**
  - Build: add `adapters/sqlite/mod.rs` that temporarily re-exports current metadata-store symbols from `crate::index`.
  - Verify: `cargo test --manifest-path vault-engine/Cargo.toml index::tests::metadata_schema_has_projection_indexes`.

- [x] **RA04.02a Move SQLite schema helpers mechanically**
  - Build: move only schema metadata, `create_schema`, projection-index creation/drop helpers, and schema metadata read/write helpers into `adapters/sqlite/schema.rs`.
  - Verify: metadata schema tests pass without changing SQL strings, table names, index names, or expected schema version.
  - Stop condition: any SQL literal diff other than path/import changes.

- [x] **RA04.02b Move SQLite storage value converters**
  - Build: move pure SQLite conversion helpers such as property value storage, attachment state/source storage, file status, tag source, scan kind, bool/int, path string, and unix-ms conversion into `adapters/sqlite/storage_values.rs`.
  - Verify: metadata insert/update tests and projection tests pass.

- [x] **RA04.02c Move SQLite row decoders**
  - Build: move `row_to_*` decoders for file, file lookup, link, tag, graph, property, heading, and attachment records into `adapters/sqlite/rows.rs`.
  - Verify: metadata projection, graph bulk-record, and attachment tests pass.
  - Stop condition: any row decoder starts returning an FFI/read-row type instead of a domain/storage projection.

- [x] **RA04.02d Move SQLite write helpers**
  - Build: move `upsert_file`, `delete_child_records`, `insert_link`, `insert_tag`, `insert_property`, `insert_heading`, and `insert_attachment` into `adapters/sqlite/writes.rs`.
  - Verify: metadata insert/update/delete, bulk replace, and atomic batch tests pass.

- [x] **RA04.02e Move SQLite read query helpers by surface**
  - Build: move read helpers in this order: file lookup/file tree, backlinks/outgoing, tags/properties/headings/attachments, graph files/edges/tags, graph counts/plans.
  - Verify: after each surface move, run the narrow test for that surface before moving the next one; inspect query count/query plan for file tree, backlinks/outgoing, properties, headings, attachments, and graph queries.
  - Stop condition: query ordering, limit semantics, partial-state behavior changes, new N+1 `get_file` calls, removed `LIMIT/OFFSET`, or indexed lookups becoming full scans.

- [x] **RA04.02f Move `MetadataStore` shell last**
  - Build: move `MetadataStore`, `IndexedFileRecords`, `MetadataStoreError`, and constructor/open methods to `adapters/sqlite/metadata_store.rs` after helpers are already under the SQLite adapter.
  - Verify: full `index::tests` filter or new `adapters::sqlite` test filter passes.

- [x] **RA04.02g Keep old `crate::index` compatibility path**
  - Build: turn `index.rs` into a temporary compatibility module that re-exports `adapters::sqlite` symbols still used by unmigrated callers.
  - Verify: `cargo test --manifest-path vault-engine/Cargo.toml` passes and `rg "crate::index::" vault-engine/src` shows only expected temporary callers.

- [x] **RA04.02h Update callers from `crate::index` to `crate::adapters::sqlite`**
  - Build: migrate callers one group at a time: read API, save/index queue, graph, indexing pipeline, diagnostics/profiler.
  - Verify: after each caller group, run that group's narrow test filter.

- [x] **RA04.02i Remove `crate::index` compatibility module**
  - Build: delete the temporary compatibility module after `rg "crate::index" vault-engine/src bench` returns no production callers.
  - Verify: full Rust tests pass.

- [x] **RA04.03 Keep metadata facade for use cases**
  - Build: expose only the crate-internal `MetadataStore` facade and intentionally shared record/projection types from `adapters::sqlite`.
  - Verify: `rg "crate::adapters::sqlite::.*row_to_|crate::adapters::sqlite::.*Connection" vault-engine/src/use_cases vault-engine/src/ffi` returns no matches.

- [x] **RA04.04 Add SQLite queue facade without moving logic**
  - Build: add `adapters/sqlite/indexing_queue.rs` as a temporary re-export or shell around current `indexing_queue.rs`.
  - Verify: queue restart and lease tests pass.

- [x] **RA04.04a Move queue schema and row conversion helpers**
  - Build: move queue schema creation, row decoding, status/reason conversion, unix-ms conversion, and error truncation into the SQLite queue adapter.
  - Verify: queue lease, retry, cancel, and coalescing tests pass.

- [x] **RA04.04b Move `IndexingQueue` store shell**
  - Build: move `IndexingQueue`, `IndexingQueueItem`, summary/error types, and methods into `adapters/sqlite/indexing_queue.rs`.
  - Verify: queue tests and indexing pipeline queue-batch tests pass.

- [x] **RA04.04c Remove old queue compatibility module**
  - Build: update all callers away from `crate::indexing_queue`, then delete or narrow the old module path.
  - Verify: `rg "crate::indexing_queue" vault-engine/src` returns no production callers.

- [x] **RA04.05 Add Tantivy adapter facade without changing config**
  - Build: add `adapters/tantivy/mod.rs` that temporarily re-exports current `tantivy_search` symbols.
  - Verify: `cargo test --manifest-path vault-engine/Cargo.toml tantivy_search::tests::safe_tantivy_query_bounds_and_quotes_user_input`.

- [x] **RA04.05a Move Tantivy schema and field helpers**
  - Build: move schema construction, stored-text extraction, and field lookup helpers into `adapters/tantivy/schema.rs` without changing field names, storage flags, tokenizer, or snippet mode.
  - Verify: search tests pass without changing expected snippets, scores, or error states.

- [x] **RA04.05b Move Tantivy query sanitization helpers**
  - Build: move `safe_tantivy_query`, first-term extraction, and snippet helpers into `adapters/tantivy/query.rs`.
  - Verify: query sanitization and snippet tests pass.

- [x] **RA04.05c Move Tantivy metrics helpers**
  - Build: move percentile/duration/directory-size helpers and indexing-stage metrics types only after search behavior is green.
  - Verify: indexing/search metrics tests pass.

- [x] **RA04.05d Move `TantivySearchIndex` shell**
  - Build: move the search index type, open/rebuild/add/commit/search methods, writer options, and error type into `adapters/tantivy/search_index.rs`.
  - Verify: Tantivy search tests and indexing pipeline tests pass.

- [x] **RA04.05e Update callers from `crate::tantivy_search`**
  - Build: migrate read API, indexing pipeline, diagnostics, and profiler imports one group at a time.
  - Verify: after each caller group, run the matching narrow test.

- [x] **RA04.05f Remove old Tantivy compatibility module**
  - Build: delete or reduce `tantivy_search.rs` after all callers use `adapters::tantivy`.
  - Verify: `rg "crate::tantivy_search" vault-engine/src bench` returns no production callers.

- [x] **RA04.05g Keep Tantivy lifecycle stable**
  - Build: no code change after RA04.05f.
  - Verify: confirm searcher/writer/index directory lifetimes are unchanged and no adapter code reopens Tantivy per read/search call. Scan FFI and read use cases for `Index::open_*`, `reader()`, `writer(`, `commit(`, and `reload(`; only handle-open/rebuild code may match.

- [x] **RA04.06 Move filesystem scanner**
  - Build: move `scanner.rs` to `adapters/fs/scanner.rs`.
  - Verify: scanner fixture tests pass and core does not import scanner.

- [x] **RA04.07 Move file watcher adapter**
  - Build: move `file_watcher.rs` to `adapters/fs/watcher.rs` or `adapters/fsevents/watcher.rs` depending on final naming.
  - Verify: watcher tests pass on macOS.

- [x] **RA04.08 Move path resolution that touches disk**
  - Build: keep disk-canonicalization and vault root opening in an adapter path if it imports filesystem APIs.
  - Verify: save path safety and scanner tests pass.

- [x] **RA04.09 Run adapter boundary scan**
  - Build: no code change after RA04.08.
  - Verify: adapters do not import `crate::ffi`, and Tantivy/SQLite adapters do not import each other's private modules.
  - Result: `core` denylist scan is clean. Adapter scan has one remaining transitional exception: `adapters/fs/note_writer.rs` still uses `save` baseline/error types. `adapters/fs/index_directory.rs` now owns adapter-local path/result types. `SnippetStorageMode` was moved to core to remove the Tantivy-to-pipeline reverse dependency.

- [x] **RA04.10 Add rebuild adversarial path tests**
  - Build: cover `index_root` inside vault, `data_directory`/`rebuild_directory` outside index root, `data == rebuild`, symlinked data/rebuild/previous-data paths pointing into the vault, validation-then-symlink-swap before destructive mutation, missing engine-owned marker files, and failed commit/abort/reset paths.
  - Verify: a sentinel vault note remains unchanged after each rejected destructive operation.

- [ ] **RA04.10b Enforce marker files before destructive index deletion**
  - Build: require an engine-owned marker file before `reset_directory`, `reset_rebuild_directory`, `abort_index_rebuild`, previous-data cleanup, and commit cleanup can remove directories.
  - Verify: tests create unmarked `data`, `rebuild`, and `previous-data` directories plus a sentinel vault note; every destructive operation rejects unmarked targets and leaves the sentinel unchanged.
  - Stop condition: any destructive operation relies only on path containment without proving the target is engine-owned.

- [ ] **RA04.10c Decide and test hardlink policy**
  - Build: document whether hardlinked markdown files are supported. If unsupported, reject or skip regular files with link count `> 1` in scanner/read/save/indexing filesystem boundaries.
  - Verify: Unix-only tests create a hardlinked note from outside the vault; scan, save baseline capture, markdown read, and queue indexing handle it consistently without exposing or mutating outside-vault content.
  - Stop condition: scanner/read/save/indexing boundaries disagree on hardlink behavior.

- [ ] **RA04.11 Post-adapter performance gate**
  - Build: no refactor code changes. Run release fixture `backend-benchmark`, `materialize-read-index`, `read-api-benchmark`, and Swift read UI probe after adapter moves are complete; if private inputs are available, also run real-vault backend and UI probes with ignored/private output paths.
  - Verify: block on `> 5%` peak RSS regression, `> 10%` SQLite/Tantivy stage regression, `> 20%` read/search p95/p99 regression, or benchmark artifacts losing `peak_rss_bytes`, `time_to_usable_samples`, stage timings, pipeline config, writer memory budget, or privacy flags.

### Phase 5: Extract Use Cases

- [x] **RA05.01 Create use-case module skeleton**
  - Build: add `vault-engine/src/use_cases/mod.rs`.
  - Verify: no behavior changes.

- [x] **RA05.02 Move `VaultReadApi` shell**
  - Build: move `VaultReadApi` type, constructor, generation getter, and open lifecycle into `use_cases/read_vault.rs`.
  - Verify: Rust read API constructor/open tests and Swift engine smoke pass.

- [x] **RA05.02a Keep read state semantics stable**
  - Build: preserve `complete`, `partial`, `stale`, `cancelled`, `error`, and `index_unavailable` mapping.
  - Verify: read FFI tests and Swift read UI probe still interpret states correctly.

- [x] **RA05.02b Move read DTOs before read behavior**
  - Build: move `PageRequest`, `ReadPage`, `ReadValue`, `ReadState`, and read open errors into `use_cases/read_vault.rs` or `use_cases/read_types.rs`.
  - Verify: read state ABI constants and read open error-code tests pass.

- [x] **RA05.02c Move file tree read method**
  - Build: move only the file tree page method and page-limit handling.
  - Verify: file tree large-page and read FFI file tree tests pass.

- [x] **RA05.02d Move file tree projection read method**
  - Build: move only display-ready file tree projection logic.
  - Verify: metadata projection tests and read FFI projection tests pass.

- [x] **RA05.02e Move file-open metadata read method**
  - Build: move only the method that returns metadata for opening a selected file.
  - Verify: read API metadata-open tests pass.

- [x] **RA05.02f Move file-name search method**
  - Build: move filename search without moving Tantivy body search or search-mode dispatch.
  - Verify: search state tests pass for filename search.

- [x] **RA05.02g Move body search method**
  - Build: move Tantivy-backed body search and result conversion without changing query sanitization or snippets.
  - Verify: Tantivy search tests and read API body-search tests pass.

- [x] **RA05.02h Move search mode dispatch**
  - Build: move the mode selection wrapper after filename and body search methods are already green.
  - Verify: combined search-mode read FFI tests pass.

- [x] **RA05.02i Move backlinks and outgoing-link panel methods**
  - Build: move only backlink/outgoing panel orchestration.
  - Verify: inspector link-panel tests pass.

- [x] **RA05.02j Move tags and properties panel methods**
  - Build: move tag/property panel orchestration and display-value conversion if it is domain-only.
  - Verify: inspector tag/property tests pass.

- [x] **RA05.02k Move headings and attachments panel methods**
  - Build: move heading/attachment panel orchestration while attachment resolution remains in its current owner until explicitly moved.
  - Verify: inspector heading/attachment tests pass.

- [x] **RA05.02l Move local graph DTOs and candidate helpers**
  - Build: move `LocalGraphRequest`, depth enum, graph node/edge DTOs, and candidate helper functions that do not query storage.
  - Verify: local graph unit tests pass.

- [x] **RA05.02m Move local graph read method**
  - Build: move local graph read orchestration while keeping whole-vault graph construction owned by the graph use case if already extracted.
  - Verify: local graph FFI tests pass.

- [x] **RA05.03 Split live preview metadata use case**
  - Build: move current-buffer link/tag/attachment metadata resolution into `use_cases/live_preview_metadata.rs`.
  - Verify: `engine_read_live_preview_metadata_uses_buffer_without_vault_scan` still passes.

- [x] **RA05.03a Retarget read FFI to use cases**
  - Build: migrate `ffi/read.rs` away from `crate::read_api`, `crate::indexing_pipeline`, `crate::index_rebuild`, and `crate::paths`; FFI should call read-vault and rebuild use-case entry points only.
  - Verify: read FFI tests, rebuild FFI tests, and Swift engine smoke pass; FFI direct-adapter scan shows only documented handle-construction exceptions.

- [x] **RA05.03b Classify parser ownership**
  - Build: either move pure Markdown parser functions/types under `core/document.rs` or `core/parser.rs`, or document `parser` as an intentional pure-domain module in `docs/architecture/rust-engine.md`.
  - Verify: `use_cases` and `ffi` do not import legacy `crate::parser` unless the exception is documented and scheduled for cleanup.

- [x] **RA05.04 Move save use case**
  - Build: create `use_cases/save_note.rs` and move only `SaveRequest`, `SaveOutcome`, conflict choice DTOs, and public orchestration entry points.
  - Verify: save safety and FFI conflict choice tests pass.

- [x] **RA05.04a Move save baseline/capture orchestration**
  - Build: move baseline capture orchestration while keeping file snapshot reads in the filesystem adapter or existing save module until RA04 filesystem moves are green.
  - Verify: baseline capture FFI and safe-save baseline tests pass.

- [x] **RA05.04b Move save write orchestration**
  - Build: move save write decision flow, conflict detection, and queue enqueue call sites without moving temp write primitives.
  - Verify: external edit/delete/replace and queue enqueue tests pass.

- [x] **RA05.04c Move save conflict choice orchestration**
  - Build: move reload, keep-as-new, and overwrite choice flow after write orchestration is green.
  - Verify: conflict reload, keep-new, overwrite, and deleted-conflict tests pass.

- [x] **RA05.04d Keep save path mutation at adapter boundary**
  - Build: no behavior change; ensure mutation-time path revalidation remains next to filesystem write primitives.
  - Verify: adversarial save path tests still pass and `use_cases/save_note.rs` does not import `std::fs`.

- [x] **RA05.04e Retarget save FFI to use cases**
  - Build: migrate `ffi/save.rs` so it decodes FFI input, calls `use_cases::save_note`, and encodes the response. It must not open `IndexingQueue`, open `VaultRoot`, or call `crate::save::*_impl` directly after this step.
  - Verify: save FFI unit tests, conflict payload JSON tests, and FFI direct-adapter scan pass.

- [x] **RA05.05 Create index rebuild use-case shell**
  - Build: create `use_cases/index_rebuild.rs` and move rebuild DTO ownership and non-pipeline entry-point shell only. Do not finalize FFI wiring until full rebuild pipeline orchestration moves in RA05.06c through RA05.06e.
  - Verify: rebuild path safety and recovery tests pass without changing full rebuild pipeline behavior.

- [x] **RA05.06 Move indexing queue processing use case**
  - Build: move queue lease/result DTOs and `process_indexing_queue_batch` shell into `use_cases/process_indexing_queue.rs`.
  - Verify: queue batch tests pass.

- [x] **RA05.06a Move queue item source resolution**
  - Build: move `source_for_queue_item` and queue item path/source mapping, keeping filesystem reads in adapters.
  - Verify: queue adapter lease and missing-file queue tests pass. Add adversarial queued-path coverage for absolute paths, `..`, NUL, URL-like prefixes, symlinked parents, symlinked note files, and DB-tampered paths; reject or treat as missing before any filesystem read.

- [x] **RA05.06b Move queue failure recording flow**
  - Build: move queue failure recording and truncation orchestration without changing retry/cancel semantics.
  - Verify: retry, cancel, and failure-truncation tests pass.

- [x] **RA05.06c Move full rebuild read/parse orchestration**
  - Build: move `run_read_parse_pipeline`, read/parse progress types, and metadata count aggregation into a use-case module while preserving worker cap and channel capacity.
  - Verify: read/parse pipeline tests pass and artifact fields preserve `read_parse_workers <= 4`, `channel_capacity == 32`, `metadata_batch_size == 256`, `writer_memory_budget_bytes == 50000000`, and `peak_in_flight_items <= workers + channel_capacity`.

- [x] **RA05.06d Move Tantivy rebuild orchestration**
  - Build: move `run_tantivy_rebuild_pipeline` and stage metrics merge logic without changing writer memory or commit timing.
  - Verify: Tantivy rebuild pipeline tests pass.

- [x] **RA05.06e Move full rebuild commit orchestration**
  - Build: move `run_full_rebuild_pipeline` and `run_full_rebuild_pipeline_and_commit` after read/parse and Tantivy rebuild pieces are green.
  - Verify: full rebuild tests and rebuild path safety tests pass.

- [x] **RA05.06f Streaming rebuild memory gate**
  - Build: no code change after RA05.06e. Rerun backend benchmark and inspect the pipeline artifact.
  - Verify: bounded in-flight counts, unchanged pipeline config, no full-corpus `Vec<SearchDocument>`, preserved `time_to_usable_samples`, and no regression beyond the backend performance gate.
  - Evidence: `docs/benchmarks/artifacts/vault-engine-architecture-fixture-ra05-06f-2026-05-27.json` keeps workers `4`, channel `32`, metadata batch `256`, Tantivy memory `50MB`, time-to-usable samples `3`, read/parse peak in-flight `5/6`, and no private-token scan matches.

- [x] **RA05.06g Retarget rebuild FFI and finalize rebuild use case**
  - Build: after full rebuild orchestration is under use cases, migrate rebuild FFI wiring away from legacy `index_rebuild` and `indexing_pipeline` entry points.
  - Verify: rebuild FFI tests, Swift engine smoke, and FFI direct-adapter scan pass.

- [x] **RA05.07a Add startup reconciliation use-case module**
  - Build: add `use_cases/reconcile_startup.rs` and `pub(crate) mod reconcile_startup;` without moving logic yet.
  - Verify: `cargo test --manifest-path vault-engine/Cargo.toml startup_reconciliation::`.
  - Stop condition: adding the module changes public exports or test behavior.

- [x] **RA05.07b Move startup reconciliation production code**
  - Build: mechanically move `StartupReconciliationSummary`, `StartupReconciliationError`, `StartupReconciliationResult`, `reconcile_startup`, and private helpers into `use_cases/reconcile_startup.rs`.
  - Verify:
    ```sh
    cargo fmt --manifest-path vault-engine/Cargo.toml --check
    cargo test --manifest-path vault-engine/Cargo.toml startup_reconciliation::
    ```
  - Stop condition: startup reconciliation test expectations, enqueue counts, or rename/delete/create semantics change.

- [ ] **RA05.07c Retarget startup reconciliation callers**
  - Build: update internal callers such as watcher burst recovery to import `crate::use_cases::reconcile_startup`; keep `startup_reconciliation.rs` as a temporary compatibility re-export only.
  - Verify:
    ```sh
    rg -n "crate::startup_reconciliation" vault-engine/src
    cargo test --manifest-path vault-engine/Cargo.toml startup_reconciliation::
    cargo test --manifest-path vault-engine/Cargo.toml watcher_burst::
    ```
  - Stop condition: any production caller except the compatibility module still depends on the legacy root module.

- [ ] **RA05.08a Add watcher burst use-case module**
  - Build: add `use_cases/watcher_burst.rs` and `pub(crate) mod watcher_burst;` without moving logic yet.
  - Verify: `cargo test --manifest-path vault-engine/Cargo.toml watcher_burst::`.

- [ ] **RA05.08b Move watcher burst coalescing logic**
  - Build: mechanically move `WatcherBurstPlan`, `WatcherBurstState`, `coalesce_watcher_burst`, `event_requires_root_rescan`, and `parent_directory` into `use_cases/watcher_burst.rs`.
  - Verify: watcher coalescing tests pass, including duplicate paths, ambiguous events, root rescan events, and dropped events without paths.
  - Stop condition: sorted path output, rescan-directory output, or state classification changes.

- [ ] **RA05.08c Move watcher burst recovery orchestration**
  - Build: move `WatcherBurstRecovery`, `WatcherBurstError`, `WatcherBurstResult`, and `recover_watcher_burst` after RA05.08b is green.
  - Verify:
    ```sh
    cargo test --manifest-path vault-engine/Cargo.toml watcher_burst::
    rg -n "crate::startup_reconciliation|crate::watcher_burst" vault-engine/src/use_cases vault-engine/src/ffi vault-engine/src/adapters
    ```
  - Stop condition: recovery starts bypassing `use_cases::reconcile_startup` or queue summary state semantics change.

- [ ] **RA05.08d Keep watcher compatibility temporary**
  - Build: leave `watcher_burst.rs` as a compatibility re-export only until Phase 7 removes transitional modules.
  - Verify: `rg -n "pub use crate::use_cases::watcher_burst" vault-engine/src/watcher_burst.rs` matches and no production logic remains in the compatibility file.

- [ ] **RA05.09a Move pure whole-vault graph builder**
  - Build: move graph builder constants, `WholeVaultGraphInputs`, `build_whole_vault_graph_snapshot`, candidate node/edge builders, and pure graph helper functions into `use_cases/build_graph.rs` while leaving DTOs in `core::graph`.
  - Verify: `cargo test --manifest-path vault-engine/Cargo.toml graph::`.
  - Stop condition: node IDs, unresolved target IDs, graph limits, partial reasons, labels, tags, or edge weights change.

- [ ] **RA05.09b Move whole-vault graph storage orchestration**
  - Build: move metadata fetch orchestration for whole-vault graph snapshots into one use-case entry point, for example `build_whole_vault_graph_from_metadata`.
  - Verify:
    ```sh
    cargo test --manifest-path vault-engine/Cargo.toml graph::
    cargo test --manifest-path vault-engine/Cargo.toml read_api::tests::whole_vault_graph
    ```
  - Stop condition: graph storage query limits, tag-fetch decision, partial graph state, or generation handling changes.

- [ ] **RA05.09c Deduplicate graph candidate helpers**
  - Build: consolidate duplicate candidate-file helpers currently owned by graph FFI/read graph surfaces into the graph use-case layer.
  - Verify:
    ```sh
    rg -n "fn graph_candidate_files|push_graph_candidate_file" vault-engine/src
    cargo test --manifest-path vault-engine/Cargo.toml read_api::tests::whole_vault_graph
    ```
  - Stop condition: more than one production implementation remains without a documented reason.

- [ ] **RA05.09d Retarget graph FFI to use cases**
  - Build: keep FFI JSON request/response DTOs in `ffi/graph.rs`, but call `use_cases::build_graph`; remove direct FFI imports of `MetadataStore`, graph SQL records, and legacy `crate::graph` orchestration.
  - Verify:
    ```sh
    cargo test --manifest-path vault-engine/Cargo.toml ffi::tests::engine_graph_snapshot_returns_payload_and_errors
    rg -n "MetadataStore|GraphFileRecord|GraphResolvedEdgeRecord|GraphUnresolvedEdgeRecord|crate::graph" vault-engine/src/ffi/graph.rs
    ```
  - Stop condition: graph FFI owns graph membership, SQL-record conversion, or metadata query decisions.

- [ ] **RA05.09e Run graph FFI ABI and smoke gate**
  - Build: no code change after RA05.09d.
  - Verify:
    ```sh
    cargo build --manifest-path vault-engine/Cargo.toml --release
    nm -gU vault-engine/target/release/libvault_engine.dylib | awk '{print $3}' | grep '^_engine_' | sort
    swift run --package-path mac-app Granite --engine-smoke-test
    ```
  - Stop condition: exported `engine_*` symbols change or Swift fails to load the dylib.

- [ ] **RA05.09f Graph snapshot memory gate**
  - Build: no behavior change after graph use-case movement. Run `vault-profiler graph-snapshot-benchmark` on a fixture first, and on the real vault only after privacy-safe output is configured.
  - Verify: enforce graph-view budgets from `docs/architecture/graph-view.md`, especially Rust snapshot duration `<= 2.5s`, Rust snapshot RSS delta `<= 250 MB`, and encoded payload `<= 64 MiB`.
  - Stop condition: graph artifact includes private note paths/content or exceeds the graph-view memory/bridge budget.

- [ ] **RA05.10a Run focused use-case boundary scan**
  - Build: no code change after RA05.09f.
  - Verify:
    ```sh
    rg -n "std::fs|OpenOptions|rename|remove_dir_all|canonicalize|symlink_metadata|MetadataExt|rusqlite|tantivy|libc|FSEvent" vault-engine/src/use_cases
    rg -n "unsafe|extern \"C\"|CStr|CString::from_raw|Vec::from_raw_parts|slice::from_raw_parts|no_mangle" vault-engine/src -g '!ffi/**' -g '!adapters/fsevents/watcher.rs' -g '!diagnostics/**'
    rg -n "crate::ffi" vault-engine/src/core vault-engine/src/use_cases vault-engine/src/adapters
    rg -n "crate::(startup_reconciliation|watcher_burst|graph)" vault-engine/src/use_cases vault-engine/src/ffi vault-engine/src/adapters
    ```
  - Stop condition: new matches are not documented as transitional exceptions. Existing legacy parser/scanner/path/indexing exceptions should be handled in their own cleanup tasks, not hidden inside RA05.10a.

- [ ] **RA05.10b Record hot-path allocation baseline**
  - Build: no behavior change; record currently allowed allocation sites before graph/diagnostics movement so later diffs can distinguish existing allocations from new regressions.
  - Verify:
    ```sh
    git diff --unified=0 -- vault-engine/src |
      rg -n '^\+.*(collect::<Vec|\.collect\(\)|\.clone\(\)|to_string\(\)|format!\(|serde_json::|Box<dyn|Arc<dyn|read_to_string|std::fs::read|Index::open_in_dir|reader\(\)|writer\(|commit\(|reload\()'
    ```
  - Stop condition: a new allocation/materialization appears in read/search/graph/indexing hot paths without benchmark evidence.

- [ ] **RA05.11 Re-run save path safety through moved use case**
  - Build: no behavior change after save use-case move.
  - Verify:
    ```sh
    cargo test --manifest-path vault-engine/Cargo.toml save::
    cargo test --manifest-path vault-engine/Cargo.toml save_note::
    cargo test --manifest-path vault-engine/Cargo.toml ffi::tests::save_ffi
    cargo test --manifest-path vault-engine/Cargo.toml ffi::tests::engine_save
    ```
  - Stop condition: external delete/edit/replace, symlink swap, new-note symlink parent, non-regular files, read-only targets, unsafe relative paths, or FFI conflict choices regress.

### Phase 6: Diagnostics, Benchmarks, And Profiler Boundary

- [ ] **RA06.01a Move benchmark module mechanically**
  - Build: move `benchmarks.rs` to `diagnostics/benchmarks.rs`; add `pub mod benchmarks;` under `diagnostics`.
  - Verify:
    ```sh
    cargo test --manifest-path vault-engine/Cargo.toml benchmarks::
    cargo test --manifest-path bench/vault-profiler/Cargo.toml
    ```
  - Stop condition: benchmark artifact schema, stage metrics, or profiler imports require behavior changes during the file move.

- [ ] **RA06.01b Keep temporary benchmark compatibility facade**
  - Build: keep `vault_engine::benchmarks` as a temporary re-export or compatibility module until `bench/vault-profiler` imports move to `vault_engine::diagnostics::benchmarks`.
  - Verify:
    ```sh
    rg -n "crate::benchmarks|vault_engine::benchmarks" vault-engine/src bench/vault-profiler/src
    cargo test --manifest-path bench/vault-profiler/Cargo.toml
    ```
  - Stop condition: Phase 7 begins while profiler still requires the legacy benchmark path.

- [ ] **RA06.02a Preserve aggregate-only privacy rules**
  - Build: ensure moved benchmark code still redacts raw note text, snippets, tags, query strings, private paths, raw relative paths, stable per-file IDs, error strings, panic payloads, `Debug` output, CLI args, and SQLite/Tantivy error messages.
  - Verify: benchmark artifact tests pass and no committed artifact contains `/Users/`, vault names, `.md` relative paths, note snippets, query terms, tags/frontmatter keys, or stable per-file IDs.

- [ ] **RA06.02b Redact profiler error notes**
  - Build: store error class/category only for committed benchmark/probe artifacts; do not persist raw `error.to_string()` values from read/search/indexing failures.
  - Verify: a fixture test injects `/Users/example/Private Vault/Secret.md`, query text, and SQLite/Tantivy path text into an error; serialized public artifacts contain none of those tokens.
  - Stop condition: any artifact field can expose raw backend error text without an explicit private-output opt-in.

- [ ] **RA06.02c Remove stable public per-file hashes**
  - Build: either omit per-sample input hashes from public artifacts or salt them per run with no committed salt-to-input mapping.
  - Verify: two public artifact generations for the same private path/query produce different hashes or no per-input hashes, and the mapping is not committed.
  - Stop condition: committed artifacts contain stable identifiers that can track the same private note across runs.

- [ ] **RA06.02d Treat vault root names as private**
  - Build: replace public artifact root-name fields with caller-supplied aliases or fixed redacted values for real-vault runs.
  - Verify: artifact privacy tests assert private vault directory names are absent.

- [ ] **RA06.03 Run fixture read/index benchmark smoke**
  - Build: run existing fixture benchmark or profiler command after diagnostics movement.
  - Verify: produced artifact remains aggregate-only and no private vault content is committed.

- [ ] **RA06.04 Keep diagnostics out of production use cases**
  - Build: ensure production modules do not import `diagnostics`.
  - Verify: `rg "crate::diagnostics" vault-engine/src/core vault-engine/src/use_cases vault-engine/src/adapters vault-engine/src/ffi` returns no matches.

- [ ] **RA06.05 Add privacy scan gate**
  - Build: after generated benchmark/probe artifacts, scan only new or modified artifacts for private-path and content tokens before commit.
  - Verify:
    ```sh
    rg -n "/Users/|\\.md\"|raw_query|relative_path\"|snippet|frontmatter|tags|file_id" docs/benchmarks/artifacts
    ```
  - Stop condition: any matched token is not an aggregate field, redacted alias, or documented fixture-only value.

- [ ] **RA06.06a Inventory profiler legacy imports**
  - Build: no code change; list every `bench/vault-profiler` import from old public modules before changing visibility.
  - Verify:
    ```sh
    rg -n "vault_engine::(attachments|index|parser|paths|scanner|sqlite_fts|tantivy_search|benchmarks|read_api)" bench/vault-profiler/src
    ```
  - Stop condition: a legacy public module is made private before its profiler import is migrated.

- [ ] **RA06.06b Create profiler-facing diagnostics facade**
  - Build: expose intentional profiler APIs through `vault_engine::diagnostics`, including benchmark types, SQLite FTS benchmark support if retained, and any read-indexer helpers that otherwise force public access to internal modules.
  - Verify:
    ```sh
    cargo test --manifest-path bench/vault-profiler/Cargo.toml
    rg -n "vault_engine::(attachments|index|parser|paths|scanner|sqlite_fts|tantivy_search|benchmarks|read_api)" bench/vault-profiler/src
    ```
  - Stop condition: `bench/vault-profiler` still imports legacy internals directly after the facade migration.

- [ ] **RA06.06c Migrate `bench/vault-profiler` imports**
  - Build: update profiler imports one group at a time: benchmarks, SQLite FTS/search DTOs, read indexer, parser/path/scanner helpers, and read API surfaces.
  - Verify: after each import group, run `cargo test --manifest-path bench/vault-profiler/Cargo.toml`.

- [ ] **RA06.07a Retarget SQLite FTS DTO imports**
  - Build: move consumers of `sqlite_fts::SearchDocument` and `sqlite_fts::SearchResult` to `core::search` or an intentional diagnostics facade before moving SQLite FTS ownership.
  - Verify:
    ```sh
    rg -n "crate::sqlite_fts|vault_engine::sqlite_fts" vault-engine/src bench/vault-profiler/src
    cargo test --manifest-path vault-engine/Cargo.toml sqlite_fts::
    cargo test --manifest-path bench/vault-profiler/Cargo.toml
    ```

- [ ] **RA06.07b Decide SQLite FTS ownership**
  - Build: document and implement whether SQLite FTS remains a production adapter under `adapters/sqlite/fts_index.rs` or becomes diagnostics-only under `diagnostics/sqlite_fts.rs`.
  - Verify: profiler and search benchmark tests pass after the decision.

- [ ] **RA06.07c Add SQLite FTS MATCH sanitization coverage**
  - Build: add tests for quotes, `OR`, `NEAR`, `*`, `:`, column selectors, parentheses, and malformed MATCH expressions.
  - Verify:
    ```sh
    cargo test --manifest-path vault-engine/Cargo.toml sqlite_fts::tests::safe_match_query
    ```
  - Stop condition: any malformed query reaches SQLite MATCH unsanitized or user input is interpolated into SQL.

- [ ] **RA06.08 Profiler artifact compatibility gate**
  - Build: no code change after diagnostics/profiler import migration. Rerun profiler parse tests plus one fixture benchmark.
  - Verify: artifacts still include `peak_rss_bytes`, `time_to_usable_samples`, stage timings, pipeline config, writer memory budget, and privacy flags.

### Phase 7: Reduce Public Surface

- [ ] **RA07.00 Preflight external Rust consumers**
  - Build: no code change; confirm `bench/vault-profiler` no longer imports legacy public modules directly before changing `lib.rs` visibility.
  - Verify:
    ```sh
    rg -n "vault_engine::(attachments|index|parser|paths|scanner|sqlite_fts|tantivy_search|benchmarks|read_api|save|graph|index_rebuild|indexing_pipeline|startup_reconciliation|watcher_burst)" bench/vault-profiler/src
    cargo test --manifest-path bench/vault-profiler/Cargo.toml
    ```
  - Stop condition: any external Rust consumer still needs an old public path that lacks a diagnostics or intentional facade replacement.

- [ ] **RA07.01 Rewrite `lib.rs` module exports**
  - Build: expose `pub mod ffi` and intentional public facades only; make internals `pub(crate)` where possible.
  - Verify: Rust tests compile without relying on unintended public modules.

- [ ] **RA07.01a Reduce public surface in two passes**
  - Build: first change `pub mod` to `pub(crate) mod` only for modules with no external Rust consumers. Then remove transitional modules in a separate step.
  - Verify: each pass compiles independently.

- [ ] **RA07.01b Make one legacy module group private at a time**
  - Build: group visibility changes by dependency family: path/scanner/parser, storage/search compatibility, save/rebuild/indexing compatibility, graph/watcher compatibility, then diagnostics/profiler facades.
  - Verify before each group:
    ```sh
    rg -n "vault_engine::<module>|crate::<module>" bench/vault-profiler/src vault-engine/src
    cargo test --manifest-path vault-engine/Cargo.toml
    cargo test --manifest-path bench/vault-profiler/Cargo.toml
    ```
  - Stop condition: a visibility change requires deleting a compatibility module or rewriting logic in the same commit.

- [ ] **RA07.01c Keep diagnostics public by design if profiler still needs it**
  - Build: if `bench/vault-profiler` remains a separate crate, expose only deliberate `diagnostics` facades and document why they are public.
  - Verify: `lib.rs` public modules are `ffi`, `diagnostics`, and any explicitly documented stable facade only.

- [ ] **RA07.02 Update health check module list**
  - Build: update `health_check()` to report architecture-level modules or intentional engine capabilities, not every internal file.
  - Verify: health check unit test and Swift engine smoke pass.

- [ ] **RA07.03 Remove transitional re-exports**
  - Build: delete compatibility modules added only for incremental migration.
  - Verify: `rg "read_ffi|crate::index::MetadataStore|crate::tantivy_search|crate::indexing_queue|crate::paths|crate::scanner|crate::parser|crate::attachments|crate::graph|crate::graph_key|crate::save|crate::read_api|crate::index_rebuild|crate::indexing_pipeline|crate::startup_reconciliation|crate::watcher_burst" vault-engine/src` returns only intentional references or none.

- [ ] **RA07.03a Remove one compatibility module per commit**
  - Build: delete compatibility modules one at a time after the matching grep is clean.
  - Verify: run the narrow test for that module plus full Rust tests after each deletion.
  - Stop condition: deleting one shim requires changing unrelated behavior or public facade policy.

- [ ] **RA07.04 Add architecture placement checklist**
  - Build: add a short checklist to `docs/architecture/rust-engine.md` explaining where new parser, storage, FFI, and use-case code should go.
  - Verify: checklist covers future work for read API, save, graph, indexing, watcher, benchmarks, and profiler imports.

- [ ] **RA07.05 Run public API grep**
  - Build: no code change after RA07.04.
  - Verify: inspect remaining `pub mod` and `pub use` entries in `vault-engine/src/lib.rs`; each has a documented reason.

- [ ] **RA07.06 Classify `errors.rs`**
  - Build: either reduce `errors.rs` to a deliberate cross-layer contract or move layer-specific errors into their owning modules before public-surface cleanup is accepted.
  - Verify: no layer imports a global error solely to avoid owning its local error mapping.

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

Prefer narrow filters before the full suite:

| Area | Narrow Verification |
| --- | --- |
| FFI health/lifecycle/read/save/graph split | `cargo test --manifest-path vault-engine/Cargo.toml ffi::` |
| Save use case or filesystem save boundary | `cargo test --manifest-path vault-engine/Cargo.toml save::` and `cargo test --manifest-path vault-engine/Cargo.toml ffi::tests::save_ffi` |
| Read API use-case move | `cargo test --manifest-path vault-engine/Cargo.toml read_api::` and `cargo test --manifest-path vault-engine/Cargo.toml ffi::tests::engine_read` |
| Metadata SQLite adapter move | `cargo test --manifest-path vault-engine/Cargo.toml index::tests::metadata_` |
| Queue SQLite adapter move | `cargo test --manifest-path vault-engine/Cargo.toml indexing_queue::` and `cargo test --manifest-path vault-engine/Cargo.toml indexing_pipeline::tests::queue_` |
| Tantivy adapter move | `cargo test --manifest-path vault-engine/Cargo.toml tantivy_search::` |
| Scanner/path adapter move | `cargo test --manifest-path vault-engine/Cargo.toml scanner::` and `cargo test --manifest-path vault-engine/Cargo.toml paths::` |
| Graph domain/use-case move | `cargo test --manifest-path vault-engine/Cargo.toml graph::` and `cargo test --manifest-path vault-engine/Cargo.toml read_api::tests::read_api_returns_paginated_metadata_and_search_states` |
| Diagnostics/profiler move | `cargo test --manifest-path vault-engine/Cargo.toml diagnostics::` and `cargo test --manifest-path bench/vault-profiler/Cargo.toml` |

If a narrow filter does not match because tests moved with the module, use the new module path filter and record the replacement command in `docs/architecture/rust-engine.md`.

Before marking any phase complete, run the full Rust suite:

```sh
cargo test --manifest-path vault-engine/Cargo.toml
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

Run at RA04.11 after Phase 4 and again after Phase 5:

- Fixture `backend-benchmark`.
- Fixture `materialize-read-index`.
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
rg -n "std::fs|OpenOptions|rename|remove_dir_all|canonicalize|symlink_metadata|MetadataExt|rusqlite|tantivy|libc|FSEvent" vault-engine/src/use_cases
rg -n "unsafe|extern \"C\"|CStr|CString::from_raw|Vec::from_raw_parts|slice::from_raw_parts|no_mangle" vault-engine/src -g '!ffi/**' -g '!adapters/fsevents/watcher.rs' -g '!diagnostics/**'
rg -n "crate::ffi" vault-engine/src/core vault-engine/src/use_cases vault-engine/src/adapters
rg -n "crate::diagnostics" vault-engine/src/core vault-engine/src/use_cases vault-engine/src/adapters vault-engine/src/ffi
rg -n "crate::(read_api|save|graph|indexing_pipeline|index_rebuild|startup_reconciliation|watcher_burst|scanner|paths|parser|attachments|graph_key)" vault-engine/src/use_cases vault-engine/src/ffi vault-engine/src/adapters
rg -n "crate::adapters::|MetadataStore|IndexingQueue|TantivySearchIndex|IndexRebuildPaths|run_full_rebuild|load_search_document_sources" vault-engine/src/ffi
rg -n "crate::adapters::(tantivy|fs|fsevents)" vault-engine/src/adapters/sqlite
rg -n "crate::adapters::(sqlite|fs|fsevents)" vault-engine/src/adapters/tantivy
rg -n "crate::adapters::(sqlite|tantivy)" vault-engine/src/adapters/fs vault-engine/src/adapters/fsevents
```

Any match must be either removed or documented as an explicit exception in `docs/architecture/rust-engine.md`.

### SQL Construction Gate

Run after SQLite adapter moves and before public-surface cleanup:

```sh
rg -n "format!|push_str|execute\\(|prepare\\(|query_map\\(|query_row\\(" vault-engine/src/adapters/sqlite
```

Expected: dynamic SQL is limited to closed enum/static fragment selection. User/vault values, paths, tags, properties, search terms, limits, and offsets must be bound parameters with clamps. Each string-building match near SQL execution must be static-only or documented.

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
- [ ] Final read/save/graph/rebuild FFI paths call use cases rather than legacy orchestration modules.
- [ ] Import boundary scans pass or documented exceptions are explicit and narrow.
- [ ] Mechanical moves and semantic extractions are separated in the implementation history.
- [ ] Unsafe/FFI grep output matches the approved allowlist; no unsafe FFI helpers drift into `core` or `use_cases`.
- [ ] `core` denylist gate passes.
- [ ] `lib.rs` exposes only intentional public facades, including a deliberate diagnostics/profiler facade if `bench/vault-profiler` remains a separate crate.
- [ ] `bench/vault-profiler` imports only intentional diagnostics/public facades, not legacy internal module paths.

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
- [ ] Paths from SQLite/JSON are revalidated at mutation boundaries and are never trusted as already safe.
- [ ] Diagnostics privacy covers error strings, panic payloads, `Debug` output, CLI args, and backend error messages.
- [ ] Post-adapter, streaming rebuild, and graph snapshot performance gates pass or the refactor stops for redesign.
- [ ] Hot-path no-allocation rules are preserved or exceptions are benchmarked and documented.
- [ ] Graph refactor preserves graph snapshot privacy and bridge gates from `docs/architecture/graph-view.md`, not only unit tests.
- [ ] Public benchmark/probe artifacts do not contain raw backend error strings, stable private-file identifiers, private vault root names, or unsalted per-input hashes.

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
| FFI keeps calling legacy modules after use-case extraction | Boundaries look clean by filename but behavior still bypasses use cases | Add explicit read/save/graph/rebuild FFI retarget tasks and direct-adapter scans |
| SQLite or JSON paths are trusted after DB tampering | Files outside the vault could be read, indexed, or mutated | Re-normalize all storage/JSON paths at filesystem mutation/read boundaries |
| Destructive index cleanup targets the wrong directory | Vault or unrelated app data can be deleted | Require engine-owned marker files plus canonical containment before destructive directory operations |
| Privacy leaks through error/debug output | Aggregate artifacts still expose note paths or content through failures | Redact error strings, panic payloads, `Debug`, CLI args, and backend error messages before artifacts are staged |
| Phase-level performance checks run too late | A regression source becomes hard to isolate | Add RA04.11, RA05.06f, RA05.09f, and RA06.08 gates at the exact risk points |
| Profiler remains an accidental public API consumer | Phase 7 cannot reduce `lib.rs` without breaking benchmark tooling | Move profiler dependencies behind `diagnostics` facades before changing module visibility |
| Stable artifact hashes identify private notes across runs | Public benchmark artifacts can leak longitudinal identity even without raw paths | Use per-run salts or omit per-input hashes from committed artifacts |

## Migration Order Rationale

1. FFI is split first because it is the largest coupling point and can be moved without changing business behavior.
2. Read ABI rows move next because they are FFI-owned by nature and have stable layout tests.
3. Core records move before adapters so storage code can depend on stable domain types.
4. Storage/platform adapters move before use cases so orchestration can be expressed against clearer dependencies.
5. Public surface cleanup happens last because early cleanup would force too many compatibility shims.

## Implementation Review Checklist

Use this checklist for each PR or worktree batch:

- [ ] Does this batch contain only one phase or a clearly contiguous subset of a phase?
- [ ] Is each commit a single RA task, or is the reason for grouping documented?
- [ ] Did the task fit the implementation unit contract, especially the move-only rule for large line-count changes?
- [ ] Are file moves separated from semantic edits?
- [ ] Did any `#[repr(C)]` struct change? If yes, stop unless explicitly planned.
- [ ] Did any C symbol name change? If yes, stop unless explicitly planned.
- [ ] Did any SQLite schema/index/query text change? If yes, split it out of this refactor.
- [ ] Did any SQL construction use string interpolation for user/vault values? If yes, replace with bound parameters before continuing.
- [ ] Did any Tantivy schema/tokenizer/writer option change? If yes, split it out.
- [ ] Did `core` gain a storage, FFI, or filesystem import?
- [ ] Did `use_cases` gain direct filesystem, SQLite, Tantivy, libc, or FSEvents imports?
- [ ] Did FFI call a legacy orchestration module instead of a use case?
- [ ] Did production code start importing `diagnostics`?
- [ ] Did a destructive operation accept a path from SQLite/JSON without re-normalizing it?
- [ ] Did a diagnostics artifact include raw paths, note text, snippets, query terms, tags, frontmatter keys, or stable file IDs?
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
- Current FFI module: `vault-engine/src/ffi/mod.rs`
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

On the active `codex/refactor-vault-engine-layered-architecture` branch, Phase 0 through Phase 4 and RA05.01 through RA05.06g are green. Remaining follow-up gates and next work:

1. RA01.12 unsafe allowlist audit if it was not already covered by existing FFI/FSEvents tests.
2. RA04.10b/RA04.10c destructive-index marker and hardlink policy follow-up gates.
3. RA04.11 post-adapter performance gate, or document why it is deferred and keep it as a merge blocker.
4. Continue RA05.07a startup reconciliation use-case module setup.

Do not start Phase 6 or Phase 7 until Phase 5 boundary scans and FFI retargeting are green.
