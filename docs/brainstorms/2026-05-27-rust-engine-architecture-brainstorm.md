---
date: 2026-05-27
topic: rust-engine-architecture
---

# Rust Engine Architecture

## What We're Solving

Granite의 Rust `vault-engine`는 현재 기능이 빠르게 추가되면서 모듈 경계가 약해졌다. 목표는 새 기능을 추가해도 품질이 무너지지 않도록 Rust 코드의 아키텍처를 정리하는 것이다.

현재 관찰:

- `vault-engine`는 `rlib`와 `cdylib`를 동시에 내보내는 단일 crate다.
- `lib.rs`가 거의 모든 내부 파일을 `pub mod`로 공개한다.
- 큰 모듈이 많다: `index.rs` 3143줄, `ffi.rs` 2529줄, `benchmarks.rs` 2382줄, `read_api.rs` 1994줄, `indexing_pipeline.rs` 1706줄, `save.rs` 1124줄, `parser.rs` 1035줄.
- `read_api`가 `graph`, `index`, `parser`, `scanner`, `sqlite_fts`, `tantivy_search`를 직접 알고 있다.
- `ffi.rs`가 ABI 함수, panic guard, C string 처리, JSON/row 변환, read/save/rebuild orchestration을 함께 가진다.
- `docs/architecture/engine-boundary.md`는 Swift/Rust ownership을 잘 정의하고 있지만, Rust 내부 모듈 구조는 그 ownership을 충분히 강제하지 못한다.

## External Research

확인한 Rust 사례와 시사점:

- `rust-analyzer`: `hir`와 `ide`를 명시적 API Boundary로 둔다. `ide`는 editor-facing POD 타입을 내보내고 내부 syntax/HIR 타입을 감춘다. LSP/JSON serialization은 최상위 `rust-analyzer` crate만 알도록 둔다. Granite에도 "Swift-facing FFI facade는 얇게, 내부 엔진 타입은 감추기"가 맞다. Source: [rust-analyzer architecture](https://rust-analyzer.github.io/book/contributing/architecture.html)
- `rust-analyzer`: `base-db`는 filesystem/path를 모르고, `project-model`이 Cargo 같은 현실 세계 모델을 abstract model로 낮춘다. Granite에도 "vault domain은 SQLite/Tantivy/FSEvents를 직접 몰라야 한다"는 방향이 맞다. Source: [project_model docs](https://rust-lang.github.io/rust-analyzer/project_model/index.html)
- Nushell: `nu-protocol`이 여러 crate에서 공유되는 structs/traits를 담아 상호 재귀 dependency를 피한다. Granite가 workspace로 갈 경우 `vault-core` 또는 `vault-protocol` 같은 공유 계약 crate가 필요하다는 근거다. Source: [nu_protocol docs](https://docs.rs/nu-protocol/latest/nu_protocol/)
- Tantivy: `Index`, `Segment`, `Schema`, `IndexWriter`, `Searcher`, `Directory`, `Tokenizer`, `Query`처럼 검색 시스템의 역할을 타입과 모듈로 분리한다. Granite 검색/metadata 경계도 storage/query/indexing 역할을 분리하는 편이 자연스럽다. Source: [Tantivy docs](https://docs.rs/tantivy/latest/tantivy/)
- Rust API Guidelines: crate API는 naming, interoperability, meaningful errors, private fields/newtypes, public dependency 관리가 중요하다. 현재 `pub mod` 과다 공개는 내부 변경 자유도를 낮추므로 공개 facade를 줄여야 한다. Source: [Rust API Guidelines checklist](https://rust-lang.github.io/api-guidelines/checklist.html)
- Rust Book module guidance: modules are for grouping related code and controlling privacy; private items are implementation details. Granite는 이 원칙을 더 적극적으로 써야 한다. Source: [Rust Book modules/privacy](https://doc.rust-lang.org/book/ch07-02-defining-modules-to-control-scope-and-privacy.html)

## Scoring Criteria

10점 만점 기준:

- 경계 명확성: domain/use-case/adapter/FFI 책임이 분리되는가.
- 현재 코드 적합도: `vault-engine`의 FFI, SQLite, Tantivy, parser, graph, save 흐름에 잘 맞는가.
- 점진적 마이그레이션: main 기능을 깨지 않고 작은 PR 단위로 옮길 수 있는가.
- 성능 안정성: 대형 vault 성능 경로를 추상화 때문에 악화시키지 않는가.
- 테스트 용이성: FFI 없이 domain/use-case를 독립 검증할 수 있는가.
- 장기 확장성: graph, summary, indexing, watcher 기능이 늘어도 구조가 버티는가.

## Candidate 1: Core + Use Cases + Adapters + Thin FFI

현재 단일 crate를 유지하되 내부를 계층화한다.

Proposed shape:

```txt
vault-engine/src/
  lib.rs
  core/
    document.rs
    path.rs
    links.rs
    metadata.rs
    graph.rs
    errors.rs
  use_cases/
    scan.rs
    rebuild_index.rs
    process_queue.rs
    read_vault.rs
    save_note.rs
    build_graph.rs
    live_preview_metadata.rs
  adapters/
    fs/
    sqlite/
    tantivy/
    fsevents/
  ffi/
    mod.rs
    read.rs
    save.rs
    graph.rs
    buffers.rs
    strings.rs
  diagnostics/
    benchmarks.rs
```

Dependency rule:

```txt
ffi -> use_cases -> core
ffi -> adapters
use_cases -> adapters traits or concrete adapters
adapters -> core
core -> no sqlite/tantivy/libc/fsevents
```

Why it fits:

- Granite already has a documented Swift/Rust boundary. This architecture makes the Rust side mirror that boundary.
- `ffi.rs` can be split first without changing Swift ABI.
- `read_api`, `save`, `indexing_pipeline`, `index_rebuild`, `startup_reconciliation`, and `watcher_burst` become use cases instead of peer modules with unclear ownership.
- `index.rs` can split into `core::metadata` records and `adapters::sqlite::metadata_store`.
- FFI remains a stable outer shell; internal Rust APIs can evolve.
- It follows rust-analyzer's boundary lesson: UI-facing facade types should be separate from internal implementation types.

Risks:

- Needs naming discipline so `use_cases` does not become a new dumping ground.
- Adapter traits should be introduced only where they reduce test friction; adding traits for every dependency would over-engineer.
- Initial migration touches module paths broadly, so it needs mechanical commits and regression probes.

Score: **9.1 / 10**

Breakdown:

- Boundary clarity: 9.5
- Current fit: 9.5
- Incremental migration: 8.5
- Performance stability: 9.0
- Testability: 9.0
- Long-term extension: 9.0

## Candidate 2: Vertical Feature Slices With Local Internals

Group by user-visible feature instead of global layers.

Proposed shape:

```txt
vault-engine/src/
  api/
    ffi/
    read_facade.rs
  features/
    file_tree/
    search/
    inspector/
    graph/
    save/
    indexing/
    watcher/
    live_preview_metadata/
  shared/
    paths.rs
    parser.rs
    metadata_records.rs
    errors.rs
    buffers.rs
```

Dependency rule:

```txt
api -> features
features -> shared
features may use adapters directly
features should not call sibling feature internals
```

Why it fits:

- Granite's work plans are already feature-oriented: read API, graph, save, live preview, summary, zoom, etc.
- It gives small migration chunks: move `graph.rs` into `features/graph`, split tests, then continue.
- It avoids a heavy architecture ceremony while reducing file sizes quickly.
- It works well when product behavior is the dominant boundary.

Risks:

- Shared concepts like `FileRecord`, `LinkEdgeRecord`, path normalization, and generation state may drift into `shared` as another large bucket.
- Cross-feature flows like save -> queue -> indexing -> read freshness need explicit contracts or feature slices will call each other ad hoc.
- FFI can still become too broad unless `api/ffi` is strongly constrained.
- It is less effective than Candidate 1 at isolating SQLite/Tantivy from domain logic.

Score: **8.0 / 10**

Breakdown:

- Boundary clarity: 7.5
- Current fit: 8.5
- Incremental migration: 9.0
- Performance stability: 8.5
- Testability: 7.5
- Long-term extension: 7.0

## Candidate 3: Multi-Crate Workspace With Protocol/Core/Adapters

Split `vault-engine` into multiple crates.

Proposed shape:

```txt
crates/
  granite-vault-protocol/   # shared records, request/response structs, stable errors
  granite-vault-core/       # domain semantics: paths, parser model, links, graph types
  granite-vault-storage/    # SQLite metadata store and queue
  granite-vault-search/     # Tantivy indexing/search
  granite-vault-engine/     # use cases/orchestration
  granite-vault-ffi/        # cdylib and C ABI only
  granite-vault-bench/      # benchmarks/probes
```

Why it fits:

- Nushell's `nu-protocol` shows the value of a shared protocol crate that prevents recursive dependencies.
- rust-analyzer shows a mature workspace with multiple API boundaries.
- A separate FFI crate would make ABI ownership explicit and keep `libc`/C buffer code out of domain crates.
- Benchmarks can depend on engine crates without pulling Swift-facing FFI.

Risks:

- Highest migration cost.
- Cargo workspace boundaries force dependency direction, which is good long-term but expensive while the engine is still moving quickly.
- Many public crate APIs need versioning discipline even though the product only needs one app-owned dylib.
- May slow small feature work until crate boundaries settle.
- It is probably premature before the single-crate internal architecture is cleaned up.

Score: **7.2 / 10**

Breakdown:

- Boundary clarity: 9.0
- Current fit: 7.0
- Incremental migration: 5.5
- Performance stability: 8.0
- Testability: 8.5
- Long-term extension: 8.5

## Recommendation

Use **Candidate 1: Core + Use Cases + Adapters + Thin FFI**.

This is the best match for Granite now because it fixes the actual problem without forcing a workspace split too early. The engine is already a Swift-facing Rust library with clear ownership responsibilities, but the code layout does not enforce them. Candidate 1 makes the architecture enforceable while preserving the existing crate, C ABI, package script, tests, and release workflow.

Candidate 2 is useful as a tactical migration style inside Candidate 1: each implementation PR can move one use case or adapter at a time. Candidate 3 should be deferred until after the internal boundaries are stable and the crate has clear seams worth enforcing with Cargo.

## Key Decisions

- Keep one `vault-engine` crate for the first architecture cleanup.
- Make `ffi` an outer adapter only; it should not own business logic.
- Make `core` independent from SQLite, Tantivy, libc, FSEvents, and filesystem crawling.
- Move orchestration into named use cases.
- Move SQLite/Tantivy/FSEvents/filesystem implementation details into adapters.
- Reduce `pub mod` exposure in `lib.rs`; export only intentional facades.
- Prefer concrete adapter structs first; introduce traits only where tests or alternate backends require them.
- Preserve the current C ABI and Swift call sites during the first migration.
- Keep performance-sensitive paths allocation-conscious; architecture must not add per-row boxing or dynamic dispatch in hot loops.

## First Migration Slice

Recommended first implementation unit:

1. Create module skeleton: `core`, `use_cases`, `adapters`, `ffi`, `diagnostics`.
2. Move FFI buffer/string/panic helpers out of `ffi.rs` into `ffi/buffers.rs`, `ffi/strings.rs`, and `ffi/panic.rs`.
3. Keep exported `extern "C"` functions unchanged.
4. Move read FFI functions into `ffi/read.rs` and save FFI functions into `ffi/save.rs`.
5. Update `lib.rs` to expose `pub mod ffi` but keep new internals `pub(crate)` where possible.
6. Run Rust tests, Swift engine smoke test, package script, and packaged smoke probes.

This slice reduces the largest coupling point first while minimizing behavioral risk.

## Acceptance Criteria

- Rust module layout has explicit outer FFI, use-case, core, adapter, and diagnostics areas.
- Existing Swift ABI symbols keep the same names and payload behavior.
- Existing package, smoke, read API, save, search, graph, and live preview metadata tests still pass.
- No generated data is written under the vault.
- No hot read/search/indexing path gets extra unbounded allocation or per-row heap indirection.
- New Rust module visibility uses `pub(crate)` by default and `pub` only for intentional API.
- Architecture rules are documented in `docs/architecture/rust-engine.md`.

## Open Questions

- 없음. 후보 3개 중 Candidate 1을 다음 계획 단계의 기본 선택으로 삼는다.

## Next Steps

-> `/workflows:plan docs/brainstorms/2026-05-27-rust-engine-architecture-brainstorm.md`
