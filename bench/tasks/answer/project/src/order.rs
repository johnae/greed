pub struct Order {
    pub items: Vec<(String, u64)>,
    pub country: String,
}

impl Order {
    /// The order's total in cents, before shipping and tax.
    pub fn subtotal(&self) -> u64 {
        self.items.iter().map(|(_, cents)| cents).sum()
    }
}
