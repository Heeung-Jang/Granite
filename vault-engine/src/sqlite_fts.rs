pub use crate::adapters::sqlite::fts_index::{
    SqliteFtsError, SqliteFtsIndex, SqliteFtsResult, safe_match_query,
};
pub use crate::core::search::{SearchDocument, SearchMeasurement, SearchResult};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn safe_match_query_sanitizes_fts_operators_and_malformed_input() {
        assert_eq!(
            safe_match_query("Home OR title:*"),
            Some("\"Home\" AND \"OR\" AND \"title\"".to_string())
        );
        assert_eq!(
            safe_match_query("\"quoted\" NEAR(body) title:secret *"),
            Some("\"quoted\" AND \"NEAR\" AND \"body\" AND \"title\" AND \"secret\"".to_string())
        );
        assert_eq!(
            safe_match_query("(alpha OR beta) -gamma +delta"),
            Some("\"alpha\" AND \"OR\" AND \"beta\" AND \"gamma\" AND \"delta\"".to_string())
        );
        assert_eq!(safe_match_query("   !!! :* () \"\"   "), None);
    }
}
