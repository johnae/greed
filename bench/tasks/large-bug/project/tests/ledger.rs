use ledger::model::Money;
use ledger::parse::entries;
use ledger::report::{balances, by_month};

const TEXT: &str = "\
; October
2026-10-01 assets:bank -> expenses:food 12.50 lunch
2026-10-03 assets:bank -> expenses:rent 800 rent
2026-11-01 income:work -> assets:bank 2000.05 pay
2026-11-02 assets:bank -> expenses:food 7.5 coffee
";

#[test]
fn money_reads_and_prints() {
    assert_eq!(Money::parse("12.5"), Some(Money(1250)));
    assert_eq!(Money::parse("-0.05"), Some(Money(-5)));
    assert_eq!(Money(-5).to_string(), "-0.05");
}

#[test]
fn balances_add_up_to_nothing() {
    let all = balances(&entries(TEXT).unwrap());
    let total = all.values().fold(Money(0), |a, b| a + *b);
    assert_eq!(total, Money(0));
    assert_eq!(all[&ledger::model::Account("assets:bank".into())], Money(118005));
}

#[test]
fn rounding_in_reports() {
    let months = by_month(&entries(TEXT).unwrap(), "expenses");
    assert_eq!(months.get("2026-10"), Some(&Money(81250)));
    assert_eq!(months.get("2026-11"), Some(&Money(750)));
}
