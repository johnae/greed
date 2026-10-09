use std::fmt;
use std::ops::{Add, Neg, Sub};

/// An amount in cents.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default)]
pub struct Money(pub i64);

impl Money {
    /// Parses "12.34", "-0.5" or "7": at most two decimals.
    pub fn parse(text: &str) -> Option<Money> {
        let text = text.trim();
        let (negative, digits) = match text.strip_prefix('-') {
            Some(rest) => (true, rest),
            None => (false, text),
        };
        let (whole, fraction) = digits.split_once('.').unwrap_or((digits, ""));
        if fraction.len() > 2 || whole.is_empty() && fraction.is_empty() {
            return None;
        }
        let whole: i64 = if whole.is_empty() { 0 } else { whole.parse().ok()? };
        let cents: i64 = match fraction.len() {
            0 => 0,
            1 => fraction.parse::<i64>().ok()? * 10,
            _ => fraction.parse().ok()?,
        };
        let total = whole * 100 + cents;
        Some(Money(if negative { -total } else { total }))
    }
}

impl Add for Money {
    type Output = Money;
    fn add(self, other: Money) -> Money {
        Money(self.0 + other.0)
    }
}

impl Sub for Money {
    type Output = Money;
    fn sub(self, other: Money) -> Money {
        Money(self.0 - other.0)
    }
}

impl Neg for Money {
    type Output = Money;
    fn neg(self) -> Money {
        Money(-self.0)
    }
}

impl fmt::Display for Money {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let sign = if self.0 < 0 { "-" } else { "" };
        let cents = self.0.abs();
        write!(f, "{sign}{}.{:02}", cents / 100, cents % 100)
    }
}
