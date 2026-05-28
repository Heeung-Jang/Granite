# Save Safety

This document freezes the F02 write ownership decision for the native macOS app.

## Ownership Rule

Swift owns user interaction and macOS access setup. Rust owns file-save validation and the write primitive.

There must be only one implementation of the destructive save path. Swift must not perform its own direct overwrite or temp-file replacement for note saves.

## Ownership Matrix

| Step | Owner | Notes |
| --- | --- | --- |
| Security-scoped bookmark access | Swift | Resolve and hold access before calling Rust when sandboxing is enabled. |
| Save command, dirty state, and prompts | Swift | Cmd+S, failed-save state, reload, keep-as-new-note, and overwrite prompts stay in UI state. |
| `NSFileCoordinator` wrapper if required | Swift | AppKit/macOS coordination belongs at the platform edge around the Rust call. |
| Relative path normalization | Rust | Reject absolute paths, traversal, URL schemes, tilde expansion, NUL bytes, and outside-vault paths. |
| Canonical path revalidation | Rust | Re-resolve the target under the vault immediately before saving. |
| Baseline validation | Rust | Compare file identity, size, modified time, and content hash against the open-file baseline. |
| Symlink swap detection | Rust | Reject symlink escapes and symlink leaf swaps before any write. |
| Read-only target detection | Rust | Refuse replacement when the target is read-only. |
| Same-directory temp write | Rust | Write exact editor bytes to a same-directory temp file. |
| Atomic replacement | Rust | Rename the same-directory temp file over the original target on macOS. |
| Permission preservation | Rust | Preserve existing file permissions where practical before replacement. |
| Buffer preservation on failure | Swift | Rust returns an error; Swift keeps the editor buffer dirty and unchanged. |
| Reindex notification | Rust initiates, Swift observes | F06 will connect successful own-save events to the indexing queue and watcher reconciliation. |

## F03 Primitive

`vault_engine::save` exposes the first safe-save spike:

- `SaveBaseline::capture(root, relative_path)` records the file identity, size, modified time, and stable content hash when a note is opened.
- `safe_save(root, SaveRequest::new(&baseline, contents))` revalidates the baseline before writing.
- The save writes the exact byte buffer supplied by Swift. Line endings, BOM, final newline, and Markdown source semantics are not transformed by Rust.
- The temp file is created in the target file's directory and renamed over the original only after validation and temp-file sync complete.
- Any conflict or IO failure returns an error and leaves dirty-buffer handling to Swift.

## F05 Conflict Choices

`vault_engine::save` exposes conflict-choice helpers for editor integration:

- `reload_after_conflict` reloads the current disk contents, returns a new baseline and clean editor state, and queues `file_changed` work.
- `keep_conflicted_buffer_as_new_note` writes the dirty buffer to a caller-provided new in-vault Markdown path, refuses existing targets, returns a new baseline and clean editor state, and queues `own_save` work.
- `overwrite_after_conflict` overwrites the current regular in-vault file only after explicit choice, returns a new baseline and clean editor state, and queues `own_save` work.

Overwrite remains unsafe for deleted, symlink-swapped, non-regular, missing, and read-only targets. Swift owns the prompt and decides which choice to call; Rust owns path validation, writes, and queueing.

## F06 Own-Save Reindexing

Successful app-owned saves should update the editor baseline and enqueue reindex work without being treated as external conflicts.

`safe_save_and_enqueue_own_save` wraps the normal safe-save primitive, returns a new clean baseline, and queues `own_save` work in `IndexingQueue`. The queue preserves same-generation `own_save` work when a watcher later reports `file_changed` for the same file, so the watcher echo does not replace the app-owned save reason or reset that work item.

The returned baseline is the editor's new source of truth. A subsequent save using that baseline must not produce a false external-change conflict.

## Fixture Policy

Write tests must never target `/Users/heeung/Documents/Codex Vault`.

Current F01/F03 tests copy `fixtures/compatibility-vault` into a temporary directory and cover:

- Normal save.
- External edit.
- External delete.
- External replace/rename.
- Read-only target.
- Symlink swap outside the vault.
- Temp-file creation failure.
- Atomic replacement failure cleanup.
- Reload conflict choice.
- Keep-as-new-note conflict choice.
- Explicit overwrite conflict choice.
- Own-save queueing.
- Same-generation watcher event preservation for own saves.

Disk-full and OS-level locked-file simulations are deferred to a later integration harness because they are not deterministic as ordinary unit tests.
