pub(crate) fn safe_tantivy_query(input: &str) -> Option<String> {
    let bounded = input.chars().take(128).collect::<String>();
    let terms = bounded
        .split(|ch: char| !ch.is_alphanumeric())
        .filter(|term| !term.is_empty())
        .take(8)
        .map(|term| format!("\"{}\"", term.replace('"', "\\\"")))
        .collect::<Vec<_>>();

    (!terms.is_empty()).then(|| terms.join(" "))
}

pub(crate) fn first_query_term(input: &str) -> Option<String> {
    input
        .split(|ch: char| !ch.is_alphanumeric())
        .find(|term| !term.is_empty())
        .map(str::to_string)
}
