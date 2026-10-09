use crate::order::Order;

/// The VAT on `order`, in cents: 25% in Sweden, none abroad.
pub fn vat(order: &Order) -> u64 {
    if order.country == "SE" { order.subtotal() / 4 } else { 0 }
}
