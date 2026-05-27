pub(crate) mod adapters;
pub mod attachments;
pub(crate) mod core;
pub mod diagnostics;
pub mod errors;
pub mod ffi;
pub mod file_watcher;
#[cfg(test)]
pub(crate) mod graph;
#[cfg(test)]
pub(crate) mod index;
pub mod index_rebuild;
pub mod indexing_pipeline;
#[cfg(test)]
pub(crate) mod indexing_queue;
pub(crate) mod parser;
pub(crate) mod paths;
#[cfg(test)]
pub(crate) mod read_api;
pub mod save;
pub(crate) mod scanner;
#[cfg(test)]
pub(crate) mod sqlite_fts;
#[cfg(test)]
pub(crate) mod startup_reconciliation;
#[cfg(test)]
pub(crate) mod tantivy_search;
pub(crate) mod use_cases;
#[cfg(test)]
pub(crate) mod watcher_burst;

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
