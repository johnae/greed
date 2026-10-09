use crate::order::Order;

const STANDARD_CENTS: u64 = 695;
const ABROAD_CENTS: u64 = 1495;
const THRESHOLD_CENTS: u64 = 7_500;

/// What shipping costs for `order`, in cents.
pub fn cost(order: &Order) -> u64 {
    if qualifies(order) {
        0
    } else if order.country == "SE" {
        STANDARD_CENTS
    } else {
        ABROAD_CENTS
    }
}

fn qualifies(order: &Order) -> bool {
    order.country == "SE" && order.subtotal() >= THRESHOLD_CENTS
}
