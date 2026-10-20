//! Addresses as headers and drafts write them: "Anna Berg <anna@x>", or
//! the address alone, several apart by commas.

/// The addresses in `list`, apart by commas, as they're written. A comma
/// in a name ("Berg, Anna <anna@x>") stays in it: a part with no `@`
/// goes with the next.
pub fn split(list: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut held = String::new();
    for part in list.split(',') {
        if !held.is_empty() {
            held.push(',');
        }
        held.push_str(part);
        if held.contains('@') {
            let one = held.trim();
            if !one.is_empty() {
                out.push(one.to_string());
            }
            held.clear();
        }
    }
    let rest = held.trim();
    if !rest.is_empty() {
        out.push(rest.to_string());
    }
    out
}

/// The address alone, lowercase: "Anna <ANNA@x>" is "anna@x".
pub fn bare(address: &str) -> String {
    let inner = address
        .rsplit_once('<')
        .map_or(address, |(_, rest)| rest.trim_end_matches('>'));
    inner.trim().to_lowercase()
}

/// An account's own addresses, bare: its `address` and its `aliases`,
/// leaving out empty ones.
pub fn own<A: AsRef<str>>(address: &str, aliases: impl IntoIterator<Item = A>) -> Vec<String> {
    std::iter::once(bare(address))
        .chain(aliases.into_iter().map(|a| bare(a.as_ref())))
        .filter(|a| !a.is_empty())
        .collect()
}

/// The name before the address, if it has one: "Anna Berg <anna@x>" is
/// Anna Berg.
pub fn name(address: &str) -> Option<String> {
    let (name, _) = address.rsplit_once('<')?;
    let name = name.trim().trim_matches('"').trim();
    (!name.is_empty()).then(|| name.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn addresses_come_apart_with_their_names() {
        let list = "Anna Berg <Anna@Example.com>, Berg, Bob <bob@x>,carl@x, ";
        let each = split(list);
        assert_eq!(
            each,
            [
                "Anna Berg <Anna@Example.com>",
                "Berg, Bob <bob@x>",
                "carl@x"
            ]
        );
        assert_eq!(bare(&each[0]), "anna@example.com");
        assert_eq!(bare("carl@x"), "carl@x");
        assert_eq!(name(&each[1]).as_deref(), Some("Berg, Bob"));
        assert_eq!(name("\"Zoë\" <z@x>").as_deref(), Some("Zoë"));
        assert_eq!(name("carl@x"), None);
        assert!(split("").is_empty());
    }
}
