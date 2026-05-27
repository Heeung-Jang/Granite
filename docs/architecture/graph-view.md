# Whole-Vault Graph View Architecture

This document is the implementation contract for the whole-vault Graph view. It defines ownership, data flow, privacy, performance gates, and keyboard/accessibility behavior.

Cold indexing is excluded from the 10-second target. The target starts when the user opens Graph while the vault index is already available and ends at the first rendered visualization.

## Ownership

| Area | Owner | Contract |
| --- | --- | --- |
| Graph membership | Rust | Rust decides which nodes and edges exist from indexed metadata. |
| Link resolution | Rust | Rust owns resolved Markdown note links, unresolved targets, duplicate edge collapsing, and generation state. |
| Tag membership | Rust | Rust reads indexed tag metadata for later presentation rules. |
| Snapshot state | Rust | Rust returns complete, partial, stale, cancelled, or error state with safe reason codes. |
| FFI envelope | Rust and Swift Core | Payloads are versioned, byte-capped, request-scoped, and count-validated before use. |
| Presentation settings | Swift Core | Swift owns viewport, selection, hover, label visibility, renderer choice, and display-only settings. |
| Layout | Swift Core | Swift computes the deterministic first layout and optional post-first-paint refinement. |
| Rendering | Swift App | Swift draws the graph in the central workspace with Metal when available and Canvas as the correctness fallback. |
| Commands | Swift App | Swift owns ribbon activation, Command-G, tab title, focus, left/right chrome behavior, and open-note routing. |
| Telemetry | Swift Core and App | Telemetry records counts, durations, coarse state, renderer kind, and redacted aliases only. |

Swift must not rescan note bodies to create whole-vault graph membership. The graph snapshot must come from Rust-owned indexed metadata.

## Implemented Parity Scope

The shipped Graph workspace is a central, Obsidian-style whole-vault graph surface. It supports:

- resolved Markdown-note links by default
- optional unresolved-link and orphan nodes
- small Obsidian-like nodes and light links
- initial fit-to-view with explicit reset-to-fit
- direct node dragging in Canvas and Metal renderers
- local graph search with highlighted matches and keyboard results
- label visibility modes
- group rules that match node labels, relative paths, or tags
- group and tag-derived node colors
- directional arrows
- node size and link thickness controls
- lightweight centered canvas title, floating graph controls, compact search overlay, and settings overlay
- central Graph activation while the left file tree/search/bookmark panel remains available
- hidden note inspector while Graph is active
- optional post-first-paint force refinement controls

The first paint remains deterministic and force-iteration-free. Force refinement is disabled by default and runs only after the first draw for the current graph request.

The graph does not claim full Obsidian parity. Attachment edges, embed edges, non-Markdown file relationships, advanced Obsidian filter grammar, saved graph presets, and plugin-provided graph behavior are deferred.

## Settings And Cache Storage

Graph settings are Swift-owned runtime settings. The app must not write graph settings, graph layout caches, benchmark artifacts, or graph telemetry into the vault or `.obsidian`.

Dragged node positions are runtime-only. They may update the in-memory layout and hit-test index for the current graph session, but they are not saved into the vault, `.obsidian`, or graph benchmark artifacts.

Graph cache keys use `GraphSettingsPrivacyKey`, which hashes search text, group rules, colors, and presentation settings before they enter cache identifiers. Layout cache writing remains opt-in; the default controller does not write layout files.

## Data Flow

1. User opens Graph from the left ribbon or Command-G.
2. Swift creates a request with a process-local request ID and semantic options.
3. Rust reads indexed metadata with bulk SQLite queries and returns a bounded graph snapshot envelope.
4. Swift validates payload version, byte size, counts, duplicate node IDs, and edge references before allocating renderer models.
5. Swift maps nodes and edges into compact index arrays.
6. Swift computes a deterministic first layout with no force iterations.
7. Swift renders the first visualization and records total first-render timing.
8. Optional refinement runs after first paint and is cancellable by request ID.

If graph generation changes during decode, layout, or draw preparation, Swift must discard the stale result or keep the previous compatible graph while a newer request runs.

## Benchmark Alias

All benchmark commands, artifacts, reports, cache keys, and logs must use `real-vault-large` for the large local benchmark vault. They must not store the absolute vault location.

## Benchmark Artifact Contract

Graph benchmark artifacts must conform to `docs/benchmarks/whole-vault-graph-artifact-schema.json`.

The schema is allowlist-based with `additionalProperties: false` at every object boundary. It stores only:

- artifact version
- timestamp
- redacted vault alias
- code revision
- graph generation and coarse state
- stage-specific measurements such as snapshot, decode, layout, draw, first-render, and interaction durations
- node and edge counts
- memory and frame-time metrics
- renderer kind
- sanitized indexed-access summaries
- bridge decision evidence when the artifact measures payload behavior
- budget pass, fail, blocked, or not-measured results

Artifacts must not store raw vault locations, note display names, tags, search text, group rules, unresolved target text, graph snapshots, or edge endpoint identities.

Stage artifacts include only the measurements that were actually run for that stage. Aggregate acceptance artifacts must include every budget result listed in this document. If a budget cannot be measured, the artifact must record a safe blocker code instead of a free-form private message.

## Timing Names

These names are shared by `OSSignposter` intervals and `AppTelemetry` summary fields:

| Stage | Signpost interval | Telemetry field |
| --- | --- | --- |
| Snapshot | `graph.snapshot` | `snapshotDurationMilliseconds` |
| Decode | `graph.decode` | `decodeDurationMilliseconds` |
| Layout | `graph.layout` | `layoutDurationMilliseconds` |
| Draw | `graph.draw` | `drawDurationMilliseconds` |
| Total first render | `graph.first_render` | `totalFirstRenderDurationMilliseconds` |
| Interaction | `graph.interaction` | `interactionDurationMilliseconds` |

Allowed public event dimensions are source enum, renderer kind, graph generation, graph state, counts, timings, memory, frame-time metrics, schema/backend versions, and redacted vault alias.

## Budgets

| Budget | Target | Hard fail |
| --- | ---: | ---: |
| Rust snapshot | `<= 2.5s` | `> 2.5s` |
| Swift decode/model prep | `<= 1.5s` | `> 1.5s` |
| Initial layout | `<= 4.0s` | `> 4.0s` |
| First draw | `<= 1.0s` | `> 1.0s` |
| Total first render | `<= 10.0s` | `> 10.0s` |
| Rust snapshot RSS delta | `<= 250 MB` | `> 250 MB` |
| Swift decode/model RSS delta | `<= 200 MB` | `> 200 MB` |
| Total graph-open RSS delta | `<= 750 MB` | `> 1 GB` |
| Main-thread contiguous stall | `<= 50ms` | `> 100ms` |
| Pan/zoom frame time p95 | `<= 16.7ms` | `> 16.7ms` |
| Pan/zoom frame time p99 | `<= 33ms` | `> 33ms` |

No phase may claim real-vault acceptance without a redacted artifact proving these budgets or recording the blocker.

## Keyboard And Accessibility

- The left ribbon Graph button opens the central Graph workspace.
- Graph activation does not replace the left sidebar with a Graph placeholder; the existing left panel remains visible.
- Command-G opens or focuses the central Graph workspace when the first responder is not a text editor or text field; text inputs keep normal editing behavior.
- Graph activation must not clear the selected note or dirty editor state.
- Graph-specific arrow-key pan, plus/minus zoom, reset command, Escape, Return, Tab, and Shift-Tab behavior is active only when graph focus owns those events.
- Text fields inside graph settings or graph search keep normal text editing behavior.
- Return opens the selected resolved node through the existing dirty-navigation guard.
- Escape clears selection, hover, search focus, or settings focus according to the current focus owner.
- Tab and Shift-Tab move through graph controls and supporting lists, not through every graph node.
- VoiceOver exposes the graph as one navigable surface plus summary, selected node details, loading/partial/error state, and a keyboard-accessible results list.

Accessibility labels may contain user-visible node labels when intentionally presenting the graph, but logs, telemetry, benchmark artifacts, and cache names must not contain those labels.

## Renderer Policy

Metal is the production renderer when a Metal device is available because the `real-vault-large` visible-window benchmark passes first draw, pan/zoom p95, pan/zoom p99, main-thread stall, total first-render, and RSS budgets. Canvas remains the correctness fallback when Metal is unavailable.

Both renderers must keep the same shared graph input contract, drag-vs-pan semantics, accessibility summary behavior, and no one-SwiftUI-view-per-node guarantee. Future renderer changes must keep the `real-vault-large` benchmark gates at or below:

- first draw `<= 1.0s`
- pan/zoom p95 `<= 16.7ms`
- pan/zoom p99 `<= 33ms`
- main-thread contiguous stall `<= 50ms` target / `> 100ms` hard fail
- total first render `<= 10.0s`

## FFI Payload Gate

Workspace UI must not depend on an unmeasured graph bridge. Before connecting the central Graph view to real data, the bridge decision must record:

- encoded payload bytes
- Rust snapshot RSS delta
- Swift decode/model duration
- Swift decode/model RSS delta
- payload version and count validation behavior

Decision thresholds:

| Result | Bridge decision |
| --- | --- |
| Encoded payload `<= 64 MiB`, decode `<= 1.5s`, Swift RSS delta `<= 200 MB` | JSON may proceed. |
| Encoded payload `> 64 MiB` or decode/RSS misses target but stays below hard safety caps | Use chunked transfer or a compact binary shape before UI integration. |
| Encoded payload `> 128 MiB`, endpoint validation is too expensive, or chunked transfer still misses budget | Use compact binary transfer before UI integration. |

Every FFI response must be versioned, request-scoped, byte-capped before decode, and rejected if counts, duplicate node IDs, enum values, or edge references are invalid.
Bridge-decision artifacts must record the payload version, request-scoped status, byte cap, count validation, duplicate-node validation, enum validation, and edge-reference validation as structured fields.

### Phase 2 Preliminary Bridge Decision

The Phase 2 bridge format may proceed as JSON for the Phase 3 FFI/client implementation, with the Phase 10 real-vault gate still allowed to promote the bridge to chunked or binary.

Evidence:

- `vault-profiler graph-snapshot-benchmark` on `small-fixture` emits a redacted snapshot artifact with `encodedPayloadBytes`, `snapshotDuration`, `rustSnapshotMemory`, caller-supplied `decodeDuration`, and caller-supplied `swiftDecodeMemory` evidence.
- `WholeVaultGraphDecodeBenchmarkTests` decodes and validates a generated `synthetic-64k` payload with `64,000` nodes and `128,000` edges under the `1.5s` decode/model budget and `200 MB` Swift RSS delta budget.
- The candidate payload is request-scoped, payload-versioned, byte-capped at `128 MiB`, count-validated, duplicate-node validated, enum-validated, and edge-reference validated before model use.

Decision: JSON is acceptable for Phase 3 only when the emitted bridge decision consumes all three gates: payload `<= 64 MiB`, Swift decode/model duration `<= 1.5s`, and Swift decode/model RSS delta `<= 200 MB`. If the Phase 10 `real-vault-large` payload exceeds `64 MiB`, decode exceeds `1.5s`, or Swift decode/model RSS exceeds `200 MB`, the bridge must switch to chunked or binary before the central Graph UI uses real data.
