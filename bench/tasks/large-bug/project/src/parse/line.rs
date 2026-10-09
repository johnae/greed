use crate::model::{Account, Entry, Money};

#[derive(Debug, PartialEq)]
pub struct ParseError {
    pub line: usize,
    pub message: String,
}

/// Entries from lines like `2026-10-09 assets:bank -> expenses:food 12.50 lunch`.
/// Blank lines and lines starting with ';' are skipped.
pub fn entries(text: &str) -> Result<Vec<Entry>, ParseError> {
    let mut out = Vec::new();
    for (i, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with(';') {
            continue;
        }
        out.push(entry(line).map_err(|message| ParseError { line: i + 1, message })?);
    }
    Ok(out)
}

fn entry(line: &str) -> Result<Entry, String> {
    let mut words = line.split_whitespace();
    let date = words.next().ok_or("no date")?.to_string();
    let from = Account(words.next().ok_or("no account to take from")?.to_string());
    if words.next() != Some("->") {
        return Err("expected ->".into());
    }
    let to = Account(words.next().ok_or("no account to put in")?.to_string());
    let amount = words.next().ok_or("no amount")?;
    let amount = Money::parse(amount).ok_or_else(|| format!("bad amount {amount}"))?;
    let note = words.collect::<Vec<_>>().join(" ");
    Ok(Entry { date, from, to, amount, note })
}
