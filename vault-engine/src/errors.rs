use std::fmt;

pub type EngineResult<T> = Result<T, EngineError>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EngineError {
    NotImplemented(&'static str),
}

impl fmt::Display for EngineError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotImplemented(module) => write!(formatter, "{module} is not implemented yet"),
        }
    }
}

impl std::error::Error for EngineError {}
