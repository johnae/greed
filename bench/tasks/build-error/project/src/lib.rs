pub struct Item {
    pub name: String,
    pub count: u32,
}

/// The items running low: fewer than `below` left.
pub fn low(items: &[Item], below: u32) -> Vec<&str> {
    items.iter().filter(|i| i.count < below).map(|i| i.name).collect()
}

/// How many there are of everything together.
pub fn total(items: &[Item]) -> u32 {
    items.iter().map(|i| i.count).sum::<u64>()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_low_items_and_totals() {
        let items = vec![
            Item { name: "nails".into(), count: 3 },
            Item { name: "screws".into(), count: 40 },
        ];
        assert_eq!(low(&items, 10), vec!["nails"]);
        assert_eq!(total(&items), 43);
    }
}
