/// Splits `total_cents` into `people` shares.
pub fn split(total_cents: u64, people: u64) -> Vec<u64> {
    let share = total_cents / people;
    vec![share; people as usize]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_evenly() {
        assert_eq!(split(900, 3), vec![300, 300, 300]);
    }
}
