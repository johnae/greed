use bill::split;

#[test]
fn shares_always_add_up_with_the_first_getting_extra_cents() {
    assert_eq!(split(10000, 3), vec![3334, 3333, 3333]);
    assert_eq!(split(1, 3), vec![1, 0, 0]);
    assert_eq!(split(900, 3), vec![300, 300, 300]);
    for total in [0, 1, 99, 1001, 123457] {
        for people in 1..9 {
            assert_eq!(split(total, people).iter().sum::<u64>(), total);
        }
    }
}
