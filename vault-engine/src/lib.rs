pub mod benchmarks;
pub mod errors;
pub mod ffi;
pub mod index;
pub mod parser;
pub mod paths;
pub mod scanner;

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
            "scanner",
            "parser",
            "paths",
            "index",
            "ffi",
            "errors",
            "benchmarks",
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
                "scanner",
                "parser",
                "paths",
                "index",
                "ffi",
                "errors",
                "benchmarks",
            ]
        );
    }
}
