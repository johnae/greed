/// Seconds in `text`: "90s", "5m" or "2h". None for anything else.
pub fn parse_duration(text: &str) -> Option<u64> {
    let text = text.trim();
    let (number, unit) = text.split_at(text.len().checked_sub(1)?);
    let n: u64 = number.parse().ok()?;
    match unit {
        "s" => Some(n),
        "m" => Some(n * 60),
        "h" => Some(n * 3600),
        _ => None,
    }
}
