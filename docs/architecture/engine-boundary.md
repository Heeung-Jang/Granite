# Engine Boundary

This document defines the initial Swift/Rust ownership contract for the native Obsidian-compatible macOS app.

## Boundary Rule

Swift owns native macOS presentation and user interaction. Rust owns vault semantics, indexing state, query execution, and all data returned across the boundary.

## Ownership Matrix

| Area | Owner | Notes |
| --- | --- | --- |
| Vault picker UI | Swift | Native folder selection, recent-vault UI, reconnect actions. |
| Security-scoped bookmarks | Swift | If sandboxing is enabled, Swift resolves and refreshes bookmarks before passing paths to Rust. |
| Path normalization | Rust | Canonicalize vault root, normalize relative paths, reject outside-root traversal, and preserve file identity metadata. |
| Link resolution | Rust | Resolve wikilinks, aliases, headings, duplicate basenames, missing links, embeds, and attachments. |
| Parser semantics | Rust | Markdown, tags, frontmatter/properties, headings, attachments, malformed input warnings. |
| Index state | Rust | File metadata, generations, stale/partial/error state, tombstones, schema/backend versions. |
| Query result state | Rust | Every query returns `complete`, `partial`, `stale`, `cancelled`, or `error`. |
| Result presentation | Swift | Render file tree, search, backlinks, tags, properties, and errors from Rust-owned state. |
| Text editing UI | Swift/AppKit | TextKit bridge, selection, focus, IME, visible decoration, undo UI. |
| Save validation and write primitive | Rust | Swift owns prompts and editor dirty state; Rust owns path revalidation, conflict checks, temp writes, and atomic replacement. |
| App-owned index directory path | Swift proposes, Rust validates | Swift knows Application Support locations; Rust validates vault identity hash, schema/backend version, and lock/rebuild paths. |
| Benchmark tooling | Rust CLI first | Swift UI instrumentation joins later after engine APIs stabilize. |

## Request IDs

- Swift assigns a monotonically increasing `request_id` per user-visible request.
- Rust echoes `request_id` on all pages, completion states, cancellation acknowledgements, and errors.
- Swift discards stale async responses when a newer request owns the same UI surface.
- Request IDs are process-local and do not need to persist across launches.

## Cancellation

- Swift may cancel search, indexing, note-open, graph, and inspector requests.
- Rust treats cancellation as best effort and returns a `cancelled` state when the request is observed before completion.
- Rust must not reuse cancelled request buffers for another request.
- Swift must not assume cancellation means no filesystem/index side effects; indexing cancellation may leave a generation in `partial` or `stale`.

## Result Pages

- Rust APIs return bounded pages for file tree, file-name search, body search, backlinks, outgoing links, tags, properties, headings, and attachments.
- Every page includes `request_id`, `page_token` or `next_page_token`, `result_state`, and `generation`.
- Swift requests additional pages explicitly and may stop pagination without notifying Rust.
- Page payloads must not require Swift to hold a previous page to interpret the current page.

## Structured Errors

Rust returns structured errors with:

- Stable error code.
- User-recoverable category when applicable.
- Request ID.
- Vault generation or file identity when relevant.
- Redacted message safe for logs.
- Optional UI display message safe for user-visible presentation.

Swift maps those errors to native UI states and must not parse free-form messages for control flow.

## Buffer Ownership

- Rust-owned strings and buffers returned over FFI must have an explicit Rust free function.
- Swift must call the matching free function exactly once for every non-null Rust-owned pointer.
- Swift-owned strings passed to Rust are valid only for the duration of the call unless Rust explicitly copies them.
- FFI payloads include ABI version checks before nontrivial calls.
- Null pointers, invalid UTF-8, oversized responses, and panic containment are tested at the FFI boundary.

## App-Owned Read Artifacts

Swift prepares an app-owned index location before opening Rust read APIs. All read artifacts live under `AppOwnedIndexLocation.dataDirectory`; UI code must use explicit location fields instead of rebuilding paths in individual views.

| Artifact | Path under `AppOwnedIndexLocation.dataDirectory` | Owner | Notes |
| --- | --- | --- | --- |
| SQLite metadata store | `metadata.sqlite` | Rust metadata store | File tree, links, tags, properties, headings, attachments, graph metadata, schema state. |
| Tantivy search index | `tantivy/` | Rust Tantivy search | File-name and body search. |
| Indexing queue | `indexing-queue.sqlite` | Rust indexing queue | Existing recoverable queue used by save/index workflows. |

The default Swift index configuration names are frozen as `metadata-v2`, `sqlite+tantivy`, and `tantivy`. Path components may sanitize those strings for filesystem safety, but the semantic configuration values passed to Rust remain unchanged.

## Read FFI ABI Manifest

The high-throughput read ABI uses Rust-owned contiguous result buffers. Swift copies all decoded value models before calling `engine_read_result_free`.

Required exported functions:

| Function | Purpose |
| --- | --- |
| `engine_read_open` | Validate metadata/Tantivy paths, schema, backend, tokenizer, and return an open-status buffer plus opaque handle. |
| `engine_read_close` | Close an opaque read handle; null-safe. |
| `engine_read_result_free` | Free every Rust-owned read result buffer. |
| `engine_read_file_tree` | Return paginated file tree rows. |
| `engine_read_search` | Return paginated file-name or body search hits. |
| `engine_read_inspector_panel` | Return one typed Inspector panel page for one note. |
| `engine_read_local_graph` | Return local graph nodes and edges for one note. |
| `engine_read_live_preview_metadata` | Resolve current-buffer links and attachments against indexed metadata. |

Common result header fields:

- `abi_version`
- `row_kind`
- `request_id`
- `generation`
- `state`
- `row_count`
- `row_stride`
- `rows_offset`
- `string_arena_offset`
- `string_arena_length`
- `next_offset`
- `error_code`
- `error_message`

Stable row kinds:

| Value | Row kind | Swift target |
| ---: | --- | --- |
| `1` | `open_status` | Read open status/error only |
| `10` | `file_tree` | `FileTreeItem` / `FileTreeSnapshot` |
| `11` | `search_hit` | `SearchHitItem` / `SearchPage` |
| `12` | `backlink` | `BacklinkItem` |
| `13` | `outgoing_link` | `OutgoingLinkItem` |
| `14` | `tag` | Inspector tag rows |
| `15` | `property` | `PropertyItem` |
| `16` | `attachment` | `AttachmentReferenceItem` |
| `17` | `graph_node` | `LocalGraphNode` |
| `18` | `graph_edge` | `LocalGraphEdge` |
| `19` | `live_preview_metadata` | Link style and embed preview maps |

Stable read state values:

| Value | State |
| ---: | --- |
| `0` | `complete` |
| `1` | `partial` |
| `2` | `stale` |
| `3` | `cancelled` |
| `4` | `error` |
| `5` | `index_unavailable` |

All ABI structs exported across FFI must be `#[repr(C)]` and use fixed-width scalar fields or string references. Rust enum layout is never part of the Swift contract.

## Read UI State Contract

Production UI must not fall back to whole-vault Swift filesystem scans when the Rust read API is unavailable. Surfaces render local state instead, preserving usable stale or partial rows whenever possible.

| Rust read state | File tree | Search | Inspector | Graph | Live Preview metadata |
| --- | --- | --- | --- | --- | --- |
| `complete` | Render rows | Render rows | Render selected panel | Render graph | Apply metadata maps |
| `partial` | Render rows and footer | Render rows and banner | Render rows and section text | Render graph and banner | Apply maps and keep editor visible |
| `stale` | Render stale rows | Render stale rows | Render stale rows | Render stale graph | Preserve last good maps until replacement arrives |
| `index_unavailable` | Empty index state | Empty index state | Current-file-only state where allowed | Section state | No whole-vault scan |
| `error` | Error state | Error state | Section error | Section error | Preserve last good maps or clear safely |

## IPC Escalation Triggers

Stay with in-process FFI while calls are bounded, cancellable, and safe to invoke from background queues.

Escalate to a helper process or IPC boundary if any of these become true:

- Rust indexing or parsing panic containment cannot be made reliable enough in-process.
- Search/index work needs separate process memory limits.
- A long-running operation cannot be cancelled without risking UI process stability.
- The FFI ABI becomes too broad to version safely.
- macOS sandbox or file coordination requirements force a separate entitlement boundary.

## Threading

- Swift never calls long-running Rust work on the main thread.
- Rust APIs document whether they are synchronous, asynchronous, cancellable, and thread-safe.
- Swift UI updates happen on the main actor after Rust results are decoded.
- Rust must bound memory per request and avoid returning unbounded arrays.

## Privacy

- Rust redacts note content, raw frontmatter values, snippets, and full note-relative paths from logs unless a user explicitly exports a private diagnostic artifact.
- Swift logs request IDs, states, durations, and redacted error codes.
- Neither side writes app-owned generated files under the vault.

## B04 Boundary Baseline

B04 exposed only:

- `engine_abi_version`
- `engine_health_check`
- `engine_string_free`

Other engine APIs were intentionally undefined until their owning work package added tests.

## Current H05 Save FFI

H05 adds the first Swift-callable save functions while keeping Rust-owned write semantics:

- `engine_save_capture_baseline(vault_path, relative_path)`
- `engine_save_write(vault_path, baseline_json, contents, contents_len)`
- `engine_save_reload_after_conflict(vault_path, queue_path, conflict_json, generation)`
- `engine_save_keep_conflict_as_new_note(vault_path, queue_path, new_relative_path, contents, contents_len, generation)`
- `engine_save_overwrite_after_conflict(vault_path, queue_path, conflict_json, contents, contents_len, generation)`

All save FFI functions return owned JSON strings that Swift must release with `engine_string_free`.
The JSON envelope is:

- `ok`: boolean success flag.
- `value`: success payload or `null`.
- `error`: structured error object or `null`.

The baseline payload is a JSON representation of the Rust save baseline with stable scalar fields for file identity, size, modified time, and content hash. Swift sends that baseline back unchanged when saving. The save payload returns the updated baseline and exact byte count written.

Save errors include `code`, `message`, optional `conflict_kind`, and optional typed `conflict` details. Conflict details preserve the Rust `SaveConflict` relative path, kind, expected baseline, and actual snapshot so Swift can present explicit reload, keep-as-new-note, and overwrite choices without reconstructing conflict evidence itself.

Conflict choice functions require a caller-provided persistent `queue_path` and `generation`. Rust opens the queue at that path and returns a queued-work summary with the outcome; the FFI does not use ephemeral in-memory queueing.

The C ABI functions catch panics and convert them into structured `panic` errors so unwinding does not cross the FFI boundary. JSON is a correctness-first bridge for H05 UI wiring; it does not freeze the final high-throughput read/query ABI shape.

## Current D07 Read API

D07 freezes the first Rust read API surface around the selected backend split:

- Tantivy owns file-name/body search result retrieval.
- SQLite metadata store owns file tree, file-open metadata, backlinks, outgoing links, tags, properties, headings, attachments, schema metadata, and indexing state.

The Rust module is `vault_engine::read_api` and currently exposes:

- `VaultReadApi`
- `PageRequest`
- `ReadPage<T>`
- `ReadValue<T>`
- `ReadState`
- `SearchHit`
- `FileOpenMetadata`

Read methods:

- `file_tree(PageRequest)`
- `file_open_metadata(file_id)`
- `file_open_metadata_with_request(request_id, file_id)`
- `file_name_search(query, PageRequest)`
- `body_search(query, PageRequest)`
- `backlinks(file_id, PageRequest)`
- `outgoing_links(file_id, PageRequest)`
- `tags(file_id, PageRequest)`
- `properties(file_id, PageRequest)`
- `headings(file_id, PageRequest)`
- `attachments(file_id, PageRequest)`

Every `ReadPage<T>` includes:

- `request_id`
- `generation`
- bounded `items`
- `next_offset`
- `state`

Every `ReadValue<T>` includes:

- `request_id`
- `generation`
- `value`
- `state`

The state enum is intentionally stable at:

- `Complete`
- `Partial`
- `Stale`
- `Cancelled`
- `Error`

D07 does not expose this module over FFI yet. FFI shape, serialization, cancellation wiring, and async request ownership remain later work, but Swift-facing implementation should build against this Rust API contract rather than the old SQLite FTS prototype directly.

## Current F03 Safe Save Spike

F02 assigns note-save validation and the write primitive to Rust. Swift owns save commands, user prompts, sandbox/security-scoped access, optional `NSFileCoordinator` wrapping, and dirty-buffer lifecycle. The detailed ownership matrix is in `docs/architecture/save-safety.md`.

The Rust module is `vault_engine::save` and currently exposes:

- `SaveBaseline`
- `SaveRequest`
- `SaveOutcome`
- `QueuedSaveOutcome`
- `SaveReloadOutcome`
- `SaveChoiceOutcome`
- `SaveConflict`
- `SaveConflictKind`
- `SaveConflictChoice`
- `SafeSaveError`
- `SaveConflictChoiceError`

The first primitive:

- Captures an open-file baseline with file identity, size, modified time, and content hash.
- Revalidates the canonical in-vault path immediately before saving.
- Rejects external edit, delete, replace/rename, symlink swap, read-only target, and temp-write failure cases covered by copied-vault tests.
- Writes exact editor bytes to a same-directory temp file before atomic replacement.
- Leaves failed-save dirty-buffer handling to Swift.
- Supports explicit conflict choices for reload, keep-as-new-note, and overwrite where safe.
- Supports own-save queueing so watcher echoes do not replace same-generation `own_save` work.

## Current E01 Indexing Queue

E01 adds `vault_engine::indexing_queue` as the Rust-owned recoverable queue for future indexing workers, FSEvents, startup reconciliation, own-save reindexing, and rebuild flows.

The queue exposes:

- `IndexingQueue`
- `IndexingQueueItem`
- `IndexingQueueReason`
- `IndexingQueueStatus`
- `IndexingQueueSummary`

The queue:

- Stores one latest-generation item per file.
- Leases bounded batches instead of returning unbounded work.
- Supports retry, terminal failure, generation cancellation, and interrupted-work recovery.
- Persists to SQLite when opened with a file path.

Detailed queue behavior is documented in `docs/architecture/indexing-queue.md`.

## Current E02 File Watcher Boundary

E02 adds `vault_engine::file_watcher` for the initial-scan watcher handoff.

The module exposes:

- `InitialScanWatcher`
- `WatchedInitialScan<T>`
- `InitialScanReconciliation`
- `InitialScanState`
- `WatcherEvent`
- `WatcherEventKind`

The watcher starts before the scanner runs, records FSEvents event position where available, buffers scan-time events, and marks the scan as `Complete`, `Stale`, or `Ambiguous`.

Detailed watcher behavior is documented in `docs/architecture/file-watching.md`.

## Current E03 Startup Reconciliation

E03 adds `vault_engine::startup_reconciliation` for comparing cached metadata with a fresh filesystem scan.

The module exposes:

- `reconcile_startup`
- `StartupReconciliationSummary`
- `StartupReconciliationError`

Reconciliation detects created, modified, deleted, incomplete, and rename-as-delete-create cases, then enqueues affected files through `IndexingQueue`.

Detailed reconciliation behavior is documented in `docs/architecture/startup-reconciliation.md`.

## Current E04 Watcher Burst Recovery

E04 adds `vault_engine::watcher_burst` for coalescing high-volume watcher events and routing stale or ambiguous states into reconciliation.

The module exposes:

- `coalesce_watcher_burst`
- `recover_watcher_burst`
- `WatcherBurstPlan`
- `WatcherBurstRecovery`
- `WatcherBurstState`
- `WatcherBurstError`

Burst recovery deduplicates changed paths, records affected rescan directories, treats dropped or root-level events as ambiguous root rescan requests, and reports `Complete`, `Stale`, or `Ambiguous` index state.

Detailed burst recovery behavior is documented in `docs/architecture/watcher-burst-recovery.md`.

## Current E05 Index Rebuild

E05 adds `vault_engine::index_rebuild` for manual and compatibility-triggered rebuild orchestration.

The module exposes:

- `start_index_rebuild`
- `open_metadata_or_start_rebuild`
- `commit_index_rebuild`
- `abort_index_rebuild`
- `IndexRebuildPaths`
- `IndexRebuildReason`
- `IndexRebuildStart`
- `IndexRebuildCommit`
- `MetadataOpenRecovery`

Rebuild validates app-owned index paths against the selected vault, starts a new generation, cancels superseded queue work, enqueues `rebuild` work for scanned files, and swaps a completed rebuild directory into the active data directory without deleting vault files.

Detailed rebuild behavior is documented in `docs/architecture/index-rebuild.md`.
