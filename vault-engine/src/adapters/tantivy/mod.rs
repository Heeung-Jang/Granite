pub(crate) mod schema;

pub(crate) use schema::{TantivyFields, search_schema, search_schema_for_snippet_mode};

#[allow(unused_imports)]
pub use crate::tantivy_search::*;
