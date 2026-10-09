use super::{Account, Money};

/// One movement: `amount` from `from` to `to`, on `date` ("2026-10-09").
#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    pub date: String,
    pub from: Account,
    pub to: Account,
    pub amount: Money,
    pub note: String,
}
