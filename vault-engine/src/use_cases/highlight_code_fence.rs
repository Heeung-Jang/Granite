use crate::adapters::tree_sitter_highlight;
use crate::core::syntax_highlighting::{
    MAX_CODE_BLOCK_BYTES, SyntaxHighlightResult, SyntaxHighlightState, SyntaxHighlightToken,
    SyntaxLanguage,
};

pub(crate) fn highlight_code_fence(
    language: SyntaxLanguage,
    code: &str,
    visible_start_utf16: u32,
    visible_len_utf16: u32,
) -> SyntaxHighlightResult {
    if code.len() > MAX_CODE_BLOCK_BYTES {
        return SyntaxHighlightResult::empty(SyntaxHighlightState::Skipped);
    }
    if matches!(language, SyntaxLanguage::Plain) {
        return SyntaxHighlightResult::empty(SyntaxHighlightState::Plain);
    }
    if !language.is_tree_sitter_supported() {
        return SyntaxHighlightResult::empty(SyntaxHighlightState::Unsupported);
    }
    match tree_sitter_highlight::highlight_code(language, code) {
        Ok(tokens) => SyntaxHighlightResult {
            state: SyntaxHighlightState::Complete,
            tokens: visible_tokens(tokens, visible_start_utf16, visible_len_utf16),
        },
        Err(_) => SyntaxHighlightResult::empty(SyntaxHighlightState::Unsupported),
    }
}

fn visible_tokens(
    tokens: Vec<SyntaxHighlightToken>,
    visible_start_utf16: u32,
    visible_len_utf16: u32,
) -> Vec<SyntaxHighlightToken> {
    if visible_len_utf16 == 0 {
        return tokens;
    }
    let visible_end = visible_start_utf16.saturating_add(visible_len_utf16);
    tokens
        .into_iter()
        .filter(|token| {
            let token_end = token.start_utf16.saturating_add(token.length_utf16);
            token.start_utf16 < visible_end && token_end > visible_start_utf16
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::syntax_highlighting::SyntaxTokenKind;

    #[test]
    fn skips_blocks_above_memory_budget() {
        let code = "a".repeat(MAX_CODE_BLOCK_BYTES + 1);

        let result = highlight_code_fence(SyntaxLanguage::Rust, &code, 0, 0);

        assert_eq!(result.state, SyntaxHighlightState::Skipped);
        assert!(result.tokens.is_empty());
    }

    #[test]
    fn filters_tokens_to_visible_utf16_window() {
        let result = highlight_code_fence(
            SyntaxLanguage::Rust,
            "fn main() {\nlet value = \"x\";\n}",
            12,
            16,
        );

        assert_eq!(result.state, SyntaxHighlightState::Complete);
        assert!(result.tokens.iter().all(|token| {
            let end = token.start_utf16 + token.length_utf16;
            token.start_utf16 < 28 && end > 12
        }));
        assert!(
            result
                .tokens
                .iter()
                .any(|token| token.kind == SyntaxTokenKind::String)
        );
    }
}
