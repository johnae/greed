use std::time::Duration;

use durations::{parse, parse_duration};

#[test]
fn old_callers_keep_working() {
    assert_eq!(parse_duration("90s"), Some(90));
    assert_eq!(parse_duration("5m"), Some(300));
    assert_eq!(parse_duration("2h"), Some(7200));
    assert_eq!(parse_duration("x"), None);
}

#[test]
fn parse_takes_combined_units() {
    assert_eq!(parse("1h30m"), Some(Duration::from_secs(5400)));
    assert_eq!(parse("2m5s"), Some(Duration::from_secs(125)));
    assert_eq!(parse("45s"), Some(Duration::from_secs(45)));
    assert_eq!(parse("1x"), None);
    assert_eq!(parse(""), None);
}
