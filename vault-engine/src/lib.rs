pub mod attachments;
pub mod benchmarks;
pub mod errors;
pub mod ffi;
pub mod file_watcher;
pub mod index;
pub mod indexing_queue;
pub mod parser;
pub mod paths;
pub mod read_api;
pub mod save;
pub mod scanner;
pub mod sqlite_fts;
pub mod startup_reconciliation;
pub mod tantivy_search;

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
            "read_api",
            "save",
            "index",
            "indexing_queue",
            "ffi",
            "errors",
            "benchmarks",
            "sqlite_fts",
            "tantivy_search",
            "startup_reconciliation",
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
                "read_api",
                "save",
                "index",
                "indexing_queue",
                "ffi",
                "errors",
                "benchmarks",
                "sqlite_fts",
                "tantivy_search",
                "startup_reconciliation",
            ]
        );
    }
}
