use tree_sitter::{Language, Node, Parser};

use crate::core::syntax_highlighting::{SyntaxHighlightToken, SyntaxLanguage, SyntaxTokenKind};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct ByteToken {
    kind: SyntaxTokenKind,
    start: usize,
    end: usize,
}

pub(crate) fn highlight_code(
    language: SyntaxLanguage,
    code: &str,
) -> Result<Vec<SyntaxHighlightToken>, String> {
    let Some(grammar) = grammar(language) else {
        return Ok(Vec::new());
    };
    let mut parser = Parser::new();
    parser
        .set_language(&grammar)
        .map_err(|error| format!("set language failed: {error}"))?;
    let Some(tree) = parser.parse(code, None) else {
        return Ok(Vec::new());
    };
    let mut tokens = Vec::new();
    collect_tokens(language, tree.root_node(), &mut tokens);
    tokens.sort_by_key(|token| (token.start, token.end, token.kind.abi_code()));
    Ok(utf16_tokens(code, compact_overlaps(tokens)))
}

fn grammar(language: SyntaxLanguage) -> Option<Language> {
    match language {
        SyntaxLanguage::Yaml => Some(tree_sitter_yaml::LANGUAGE.into()),
        SyntaxLanguage::Json => Some(tree_sitter_json::LANGUAGE.into()),
        SyntaxLanguage::Java => Some(tree_sitter_java::LANGUAGE.into()),
        SyntaxLanguage::Swift => Some(tree_sitter_swift::LANGUAGE.into()),
        SyntaxLanguage::Rust => Some(tree_sitter_rust::LANGUAGE.into()),
        SyntaxLanguage::Bash => Some(tree_sitter_bash::LANGUAGE.into()),
        SyntaxLanguage::JavaScript => Some(tree_sitter_javascript::LANGUAGE.into()),
        SyntaxLanguage::TypeScript => Some(tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into()),
        SyntaxLanguage::Python => Some(tree_sitter_python::LANGUAGE.into()),
        SyntaxLanguage::Html => Some(tree_sitter_html::LANGUAGE.into()),
        SyntaxLanguage::Css => Some(tree_sitter_css::LANGUAGE.into()),
        _ => None,
    }
}

fn collect_tokens(language: SyntaxLanguage, node: Node<'_>, tokens: &mut Vec<ByteToken>) {
    if let Some(kind) = classify(language, node) {
        let start = node.start_byte();
        let end = node.end_byte();
        if end > start {
            tokens.push(ByteToken { kind, start, end });
        }
    }
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_tokens(language, child, tokens);
    }
}

fn classify(language: SyntaxLanguage, node: Node<'_>) -> Option<SyntaxTokenKind> {
    if is_property_key(language, node) {
        return Some(SyntaxTokenKind::PropertyKey);
    }
    let kind = node.kind();
    if kind.contains("comment") {
        return Some(SyntaxTokenKind::Comment);
    }
    if is_string_kind(kind) {
        return Some(SyntaxTokenKind::String);
    }
    if is_number_kind(kind) {
        return Some(SyntaxTokenKind::Number);
    }
    if is_keyword(language, kind) {
        return Some(SyntaxTokenKind::Keyword);
    }
    if is_operator(kind) {
        return Some(SyntaxTokenKind::Operator);
    }
    None
}

fn is_property_key(language: SyntaxLanguage, node: Node<'_>) -> bool {
    match language {
        SyntaxLanguage::Json => parent_first_named_child_is(node, "pair"),
        SyntaxLanguage::Yaml => ancestor_first_named_child_is(node, "block_mapping_pair"),
        _ => false,
    }
}

fn parent_first_named_child_is(node: Node<'_>, parent_kind: &str) -> bool {
    let Some(parent) = node.parent() else {
        return false;
    };
    parent.kind() == parent_kind && parent.named_child(0).map(|child| child.id()) == Some(node.id())
}

fn ancestor_first_named_child_is(node: Node<'_>, ancestor_kind: &str) -> bool {
    let mut child = node;
    while let Some(parent) = child.parent() {
        if parent.kind() == ancestor_kind {
            return parent.named_child(0).map(|first_child| first_child.id()) == Some(child.id());
        }
        child = parent;
    }
    false
}

fn is_string_kind(kind: &str) -> bool {
    kind.contains("string")
        || kind == "char_literal"
        || kind == "character_literal"
        || kind == "raw_string_literal"
}

fn is_number_kind(kind: &str) -> bool {
    kind.contains("number")
        || kind.contains("integer")
        || kind.contains("float")
        || kind == "decimal_integer_literal"
        || kind == "integer_literal"
}

fn is_keyword(language: SyntaxLanguage, kind: &str) -> bool {
    match language {
        SyntaxLanguage::Rust => matches!(
            kind,
            "as" | "async"
                | "await"
                | "break"
                | "const"
                | "continue"
                | "crate"
                | "else"
                | "enum"
                | "extern"
                | "false"
                | "fn"
                | "for"
                | "if"
                | "impl"
                | "in"
                | "let"
                | "loop"
                | "match"
                | "mod"
                | "move"
                | "mut"
                | "pub"
                | "ref"
                | "return"
                | "self"
                | "static"
                | "struct"
                | "super"
                | "trait"
                | "true"
                | "type"
                | "unsafe"
                | "use"
                | "where"
                | "while"
        ),
        SyntaxLanguage::Java | SyntaxLanguage::JavaScript | SyntaxLanguage::TypeScript => matches!(
            kind,
            "abstract"
                | "await"
                | "boolean"
                | "break"
                | "case"
                | "catch"
                | "class"
                | "const"
                | "continue"
                | "default"
                | "do"
                | "else"
                | "extends"
                | "false"
                | "final"
                | "finally"
                | "for"
                | "function"
                | "if"
                | "implements"
                | "import"
                | "instanceof"
                | "interface"
                | "let"
                | "new"
                | "null"
                | "package"
                | "private"
                | "protected"
                | "public"
                | "return"
                | "static"
                | "super"
                | "switch"
                | "this"
                | "throw"
                | "true"
                | "try"
                | "var"
                | "void"
                | "while"
        ),
        SyntaxLanguage::Swift => matches!(
            kind,
            "actor"
                | "as"
                | "associatedtype"
                | "await"
                | "break"
                | "case"
                | "catch"
                | "class"
                | "continue"
                | "defer"
                | "do"
                | "else"
                | "enum"
                | "extension"
                | "false"
                | "for"
                | "func"
                | "guard"
                | "if"
                | "import"
                | "in"
                | "init"
                | "let"
                | "nil"
                | "private"
                | "protocol"
                | "public"
                | "return"
                | "self"
                | "static"
                | "struct"
                | "switch"
                | "throw"
                | "throws"
                | "true"
                | "try"
                | "var"
                | "where"
                | "while"
        ),
        SyntaxLanguage::Python => matches!(
            kind,
            "and"
                | "as"
                | "assert"
                | "async"
                | "await"
                | "break"
                | "class"
                | "continue"
                | "def"
                | "del"
                | "elif"
                | "else"
                | "except"
                | "False"
                | "finally"
                | "for"
                | "from"
                | "global"
                | "if"
                | "import"
                | "in"
                | "is"
                | "lambda"
                | "None"
                | "nonlocal"
                | "not"
                | "or"
                | "pass"
                | "raise"
                | "return"
                | "True"
                | "try"
                | "while"
                | "with"
                | "yield"
        ),
        SyntaxLanguage::Bash => matches!(
            kind,
            "case"
                | "do"
                | "done"
                | "elif"
                | "else"
                | "esac"
                | "fi"
                | "for"
                | "function"
                | "if"
                | "in"
                | "then"
                | "while"
        ),
        SyntaxLanguage::Json | SyntaxLanguage::Yaml => {
            matches!(kind, "true" | "false" | "null" | "boolean_scalar")
        }
        SyntaxLanguage::Css | SyntaxLanguage::Html => false,
        _ => false,
    }
}

fn is_operator(kind: &str) -> bool {
    matches!(
        kind,
        "=" | "=="
            | "==="
            | "!="
            | "!=="
            | "+"
            | "-"
            | "*"
            | "/"
            | "%"
            | "<"
            | ">"
            | "<="
            | ">="
            | "&&"
            | "||"
            | "!"
            | "=>"
            | "->"
            | "::"
            | ":"
            | "."
            | ","
            | ";"
            | "?"
            | "??"
            | "|"
    )
}

fn compact_overlaps(tokens: Vec<ByteToken>) -> Vec<ByteToken> {
    let mut result = Vec::with_capacity(tokens.len());
    let mut occupied_end = 0usize;
    for token in tokens {
        if token.start < occupied_end {
            continue;
        }
        occupied_end = token.end;
        result.push(token);
    }
    result
}

fn utf16_tokens(code: &str, tokens: Vec<ByteToken>) -> Vec<SyntaxHighlightToken> {
    let mut result = Vec::with_capacity(tokens.len());
    let mut cursor_byte = 0usize;
    let mut cursor_utf16 = 0usize;
    for token in tokens {
        if token.end > code.len() || token.start > token.end {
            continue;
        }
        if token.start < cursor_byte {
            continue;
        }
        let Some(prefix) = code.get(cursor_byte..token.start) else {
            continue;
        };
        cursor_utf16 += prefix.encode_utf16().count();
        let start_utf16 = cursor_utf16;
        let Some(segment) = code.get(token.start..token.end) else {
            continue;
        };
        let length_utf16 = segment.encode_utf16().count();
        if length_utf16 == 0 {
            continue;
        }
        cursor_byte = token.end;
        cursor_utf16 += length_utf16;
        result.push(SyntaxHighlightToken {
            kind: token.kind,
            start_utf16: checked_u32(start_utf16),
            length_utf16: checked_u32(length_utf16),
        });
    }
    result
}

fn checked_u32(value: usize) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn highlights_rust_keywords_strings_and_comments() {
        let code = r#"fn main() {
    let value = "hello";
    // comment
}"#;

        let tokens = highlight_code(SyntaxLanguage::Rust, code).expect("highlight");

        assert!(
            tokens
                .iter()
                .any(|token| token.kind == SyntaxTokenKind::Keyword)
        );
        assert!(
            tokens
                .iter()
                .any(|token| token.kind == SyntaxTokenKind::String)
        );
        assert!(
            tokens
                .iter()
                .any(|token| token.kind == SyntaxTokenKind::Comment)
        );
    }

    #[test]
    fn highlights_json_property_keys_and_values() {
        let code = r#"{"name": "granite", "count": 3}"#;

        let tokens = highlight_code(SyntaxLanguage::Json, code).expect("highlight");

        assert!(
            tokens
                .iter()
                .any(|token| token.kind == SyntaxTokenKind::PropertyKey)
        );
        assert!(
            tokens
                .iter()
                .any(|token| token.kind == SyntaxTokenKind::String)
        );
        assert!(
            tokens
                .iter()
                .any(|token| token.kind == SyntaxTokenKind::Number)
        );
    }

    #[test]
    fn highlights_yaml_property_keys_and_values() {
        let code = "title: Granite\ncount: 3\n# local\n";

        let tokens = highlight_code(SyntaxLanguage::Yaml, code).expect("highlight");

        assert!(
            tokens
                .iter()
                .any(|token| token.kind == SyntaxTokenKind::PropertyKey)
        );
        assert!(
            tokens
                .iter()
                .any(|token| token.kind == SyntaxTokenKind::Number)
        );
        assert!(
            tokens
                .iter()
                .any(|token| token.kind == SyntaxTokenKind::Comment)
        );
    }
}
