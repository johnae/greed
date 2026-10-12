//! Comparing values the way filters do, the same in a log's lines and a
//! table's rows: `level>=warn`, `RESTARTS>0`, `AGE<1h`, `MEMORY>512Mi`,
//! `STATUS=Running`, `msg~timeout`.
//!
//! Numbers compare as numbers, with sizes (`512Mi`, `1.5G`, `250m`), `%` and
//! durations (`3d16h`, `500ms`); log levels in their order (debug before
//! info before warn); anything else as text, without minding case.

use std::cmp::Ordering;

/// How a filter compares a value with what it was given.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Op {
    /// `=`: the same.
    Eq,
    /// `!=`: not the same.
    Ne,
    /// `~`: has it in it.
    Has,
    /// `!~`: doesn't.
    Lacks,
    Less,
    AtMost,
    More,
    AtLeast,
}

/// The operators, those of two characters first, so `<=` isn't read as `<`.
const SIGNS: [(&str, Op); 8] = [
    (">=", Op::AtLeast),
    ("<=", Op::AtMost),
    ("!=", Op::Ne),
    ("!~", Op::Lacks),
    ("=", Op::Eq),
    ("~", Op::Has),
    (">", Op::More),
    ("<", Op::Less),
];

impl Op {
    /// The first operator in `text`: its byte offset, the operator and how
    /// long it's written. At one place, the longest.
    pub fn find(text: &str) -> Option<(usize, Op, usize)> {
        let at = text.find(['=', '!', '<', '>', '~'])?;
        let rest = &text[at..];
        SIGNS
            .iter()
            .find(|(sign, _)| rest.starts_with(sign))
            .map(|(sign, op)| (at, *op, sign.len()))
            // A lone `!` isn't one; look past it.
            .or_else(|| {
                let (next, op, len) = Op::find(&text[at + 1..])?;
                Some((at + 1 + next, op, len))
            })
    }

    /// The operator written `sign`.
    pub fn parse(sign: &str) -> Option<Op> {
        SIGNS.iter().find(|(s, _)| *s == sign).map(|(_, op)| *op)
    }

    pub fn sign(self) -> &'static str {
        SIGNS
            .iter()
            .find(|(_, op)| *op == self)
            .map_or("=", |(sign, _)| sign)
    }
}

/// Whether `have` passes `op` against `want`. With `durations`, a lone `m`
/// is minutes (an AGE column), else thousandths (kubectl's CPU).
pub fn passes(have: &str, op: Op, want: &str, durations: bool) -> bool {
    match op {
        Op::Has | Op::Lacks => {
            let has = have.to_lowercase().contains(&want.to_lowercase());
            has == (op == Op::Has)
        }
        Op::Eq => order(have, want, durations).is_eq(),
        Op::Ne => order(have, want, durations).is_ne(),
        Op::Less => order(have, want, durations).is_lt(),
        Op::AtMost => order(have, want, durations).is_le(),
        Op::More => order(have, want, durations).is_gt(),
        Op::AtLeast => order(have, want, durations).is_ge(),
    }
}

/// How `a` and `b` compare: as numbers when both are one, a number before
/// what isn't; as log levels when both are one; else as text, without
/// minding case.
pub fn order(a: &str, b: &str, durations: bool) -> Ordering {
    match (number(a, durations), number(b, durations)) {
        (Some(x), Some(y)) => return x.partial_cmp(&y).unwrap_or(Ordering::Equal),
        (Some(_), None) => return Ordering::Less,
        (None, Some(_)) => return Ordering::Greater,
        (None, None) => {}
    }
    let (a, b) = (a.trim().to_lowercase(), b.trim().to_lowercase());
    match (level(&a), level(&b)) {
        (Some(x), Some(y)) => x.cmp(&y),
        _ => a.cmp(&b),
    }
}

/// How severe a log level is, as logs spell them, lowercase.
pub fn level(name: &str) -> Option<u8> {
    Some(match name {
        "trace" => 0,
        "debug" => 1,
        "info" => 2,
        "notice" => 3,
        "warn" | "warning" => 4,
        "error" | "err" => 5,
        "critical" | "crit" => 6,
        "fatal" | "panic" | "alert" | "emerg" => 7,
        _ => return None,
    })
}

/// Whether `text` reads as a duration with a unit only durations have
/// (hours, days, seconds, weeks, years): then a column of them takes `12m`
/// as minutes.
pub fn is_duration(text: &str) -> bool {
    let token = text.split_whitespace().next().unwrap_or_default();
    token.contains(['y', 'w', 'd', 'h', 's']) && duration(token).is_some()
}

/// `text` as a number: its first word, with a size suffix (`512Mi`, `1.5G`,
/// `250m`), a `%`, or a duration in seconds (`3d16h`, `500ms`; a lone `m`
/// is minutes only with `durations`). "3 (3d16h ago)" is 3.
pub fn number(text: &str, durations: bool) -> Option<f64> {
    let token = text.split_whitespace().next()?;
    if let Ok(plain) = token.parse::<f64>() {
        return plain.is_finite().then_some(plain);
    }
    let digits = token
        .find(|c: char| !(c.is_ascii_digit() || matches!(c, '.' | '-' | '+')))
        .unwrap_or(token.len());
    let (amount, suffix) = token.split_at(digits);
    let suffix = suffix.strip_suffix('%').unwrap_or(suffix);
    let Ok(n) = amount.parse::<f64>() else {
        return duration(token);
    };
    if suffix == "m" && durations {
        return Some(n * 60.0);
    }
    scale(suffix)
        .map(|scale| n * scale)
        .or_else(|| duration(token))
}

/// What a size suffix multiplies by: k, M, G (powers of 1000), Ki, Mi, Gi
/// (of 1024), with or without B, and m for thousandths (kubectl's CPU).
fn scale(suffix: &str) -> Option<f64> {
    const PREFIXES: [(&str, i32); 6] = [("K", 1), ("M", 2), ("G", 3), ("T", 4), ("P", 5), ("E", 6)];
    match suffix {
        "" | "B" => return Some(1.0),
        "m" => return Some(1e-3),
        "k" | "kB" => return Some(1e3),
        _ => {}
    }
    let (power, rest) = PREFIXES
        .iter()
        .find_map(|(letter, power)| Some((*power, suffix.strip_prefix(letter)?)))?;
    match rest {
        "" | "B" => Some(1000f64.powi(power)),
        "i" | "iB" => Some(1024f64.powi(power)),
        _ => None,
    }
}

/// `token` as a duration like kubectl's ages (`45s`, `3d16h`) or a log's
/// (`500ms`, `1.5s`), in seconds.
fn duration(token: &str) -> Option<f64> {
    // Seconds in each unit, `ms` before `m`.
    const UNITS: [(&str, f64); 7] = [
        ("ms", 1e-3),
        ("y", 365.0 * 86400.0),
        ("w", 7.0 * 86400.0),
        ("d", 86400.0),
        ("h", 3600.0),
        ("m", 60.0),
        ("s", 1.0),
    ];
    let mut total = 0.0;
    let mut rest = token;
    while !rest.is_empty() {
        let digits = rest
            .find(|c: char| !(c.is_ascii_digit() || c == '.'))
            .filter(|at| *at > 0)?;
        let amount: f64 = rest[..digits].parse().ok()?;
        let after = &rest[digits..];
        let (unit, seconds) = UNITS.iter().find(|(unit, _)| after.starts_with(unit))?;
        total += amount * seconds;
        rest = &after[unit.len()..];
    }
    Some(total)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers_read_sizes_percentages_and_durations() {
        assert_eq!(number("3 (3d16h ago)", false), Some(3.0));
        assert_eq!(number("512Mi", false), Some(512.0 * 1024.0 * 1024.0));
        assert_eq!(number("1.5G", false), Some(1.5e9));
        assert_eq!(number("250m", false), Some(0.25));
        assert_eq!(number("12m", true), Some(720.0));
        assert_eq!(number("12.5%", false), Some(12.5));
        assert_eq!(number("3d16h", false), Some(3.0 * 86400.0 + 16.0 * 3600.0));
        assert_eq!(number("500ms", false), Some(0.5));
        assert_eq!(number("Running", false), None);
        assert_eq!(number("", false), None);
        assert!(is_duration("45s") && is_duration("2h") && !is_duration("12m"));
    }

    #[test]
    fn values_order_as_numbers_then_levels_then_text() {
        assert!(passes("12 (5s ago)", Op::More, "0", false));
        assert!(passes("1.5s", Op::More, "500ms", false));
        assert!(passes("1Gi", Op::More, "512Mi", false));
        assert!(passes("WARN", Op::AtLeast, "warn", false));
        assert!(passes("error", Op::More, "warning", false));
        assert!(!passes("debug", Op::AtLeast, "info", false));
        assert!(passes("Running", Op::Eq, "running", false));
        assert!(!passes("Running", Op::Eq, "run", false));
        assert!(passes("request timeout", Op::Has, "TIMEOUT", false));
        assert!(passes("ok", Op::Lacks, "timeout", false));
        assert!(passes("3.0", Op::Eq, "3", false));
        assert!(passes("b", Op::Ne, "a", false));
        assert_eq!(order("10", "9", false), Ordering::Greater);
        assert_eq!(order("9", "abc", false), Ordering::Less, "numbers first");
    }

    #[test]
    fn the_first_operator_is_found_the_longest_at_its_place() {
        assert_eq!(Op::find("NAME=a<b"), Some((4, Op::Eq, 1)));
        assert_eq!(Op::find("AGE <= 1h"), Some((4, Op::AtMost, 2)));
        assert_eq!(Op::find("level!=debug"), Some((5, Op::Ne, 2)));
        assert_eq!(Op::find("msg!~ok"), Some((3, Op::Lacks, 2)));
        assert_eq!(Op::find("wow! x>1"), Some((6, Op::More, 1)));
        assert_eq!(Op::find("plain"), None);
        assert_eq!(Op::parse(">="), Some(Op::AtLeast));
        assert_eq!(Op::AtLeast.sign(), ">=");
    }
}
