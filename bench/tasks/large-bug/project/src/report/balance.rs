use std::collections::BTreeMap;

use crate::model::{Account, Entry, Money};

/// Each account's balance after `entries`: what came in less what went out.
pub fn balances(entries: &[Entry]) -> BTreeMap<Account, Money> {
    let mut out: BTreeMap<Account, Money> = BTreeMap::new();
    for e in entries {
        *out.entry(e.from.clone()).or_default() = out.get(&e.from).copied().unwrap_or_default() - e.amount;
        *out.entry(e.to.clone()).or_default() = out.get(&e.to).copied().unwrap_or_default() + e.amount;
    }
    out
}

/// Balances summed by each account's top part ("assets", "expenses").
pub fn by_top(entries: &[Entry]) -> BTreeMap<String, Money> {
    let mut out: BTreeMap<String, Money> = BTreeMap::new();
    for (account, money) in balances(entries) {
        let sum = out.entry(account.top().to_string()).or_default();
        *sum = *sum + money;
    }
    out
}
