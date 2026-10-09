use scores::{mean, passing};

#[test]
fn mean_of_all_scores() {
    assert_eq!(mean(&[2, 4, 6]), Some(4.0));
    assert_eq!(mean(&[]), None);
}

#[test]
fn passing_includes_the_pass_mark() {
    assert_eq!(passing(&[40, 50, 60], 50), vec![50, 60]);
}
