use std::collections::BTreeMap;

use crate::model::{Entry, Money};

/// What went into accounts under `top` ("expenses") each month ("2026-10").
pub fn by_month(entries: &[Entry], top: &str) -> BTreeMap<String, Money> {
    let mut out: BTreeMap<String, Money> = BTreeMap::new();
    for e in entries.iter().filter(|e| e.to.top() == top) {
        let month = e.date[..6].to_string();
        let sum = out.entry(month).or_default();
        *sum = *sum + e.amount;
    }
    out
}
