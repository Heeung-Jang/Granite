pub mod attachments;
pub mod benchmarks;
pub(crate) mod core;
pub mod diagnostics;
pub mod errors;
pub mod ffi;
pub mod file_watcher;
pub mod graph;
pub(crate) mod graph_key;
pub mod index;
pub mod index_rebuild;
pub mod indexing_pipeline;
pub mod indexing_queue;
pub mod parser;
pub mod paths;
pub mod read_api;
pub mod save;
pub mod scanner;
pub mod sqlite_fts;
pub mod startup_reconciliation;
pub mod tantivy_search;
pub mod watcher_burst;

pub const ENGINE_ABI_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineHealth {
    pub abi_version: u32,
    pub modules: &'static [&'static str],
}

pub fn health_check() -> EngineHealth {
    EngineHealth {
        abi_version: ENGINE_ABI_VERSION,
        modules: &[
            "attachments",
            "scanner",
            "parser",
            "paths",
            "file_watcher",
            "graph",
            "read_api",
            "read_ffi",
            "save",
            "index",
            "index_rebuild",
            "indexing_pipeline",
            "indexing_queue",
            "ffi",
            "errors",
            "benchmarks",
            "diagnostics",
            "sqlite_fts",
            "tantivy_search",
            "startup_reconciliation",
            "watcher_burst",
        ],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn health_check_reports_expected_modules() {
        let health = health_check();

        assert_eq!(health.abi_version, 1);
        assert_eq!(
            health.modules,
            &[
                "attachments",
                "scanner",
                "parser",
                "paths",
                "file_watcher",
                "graph",
                "read_api",
                "read_ffi",
                "save",
                "index",
                "index_rebuild",
                "indexing_pipeline",
                "indexing_queue",
                "ffi",
                "errors",
                "benchmarks",
                "diagnostics",
                "sqlite_fts",
                "tantivy_search",
                "startup_reconciliation",
                "watcher_burst",
            ]
        );
    }
}
