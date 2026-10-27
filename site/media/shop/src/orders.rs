use std::collections::HashMap;

pub struct Order {
    pub id: u64,
    pub customer: String,
    pub lines: Vec<Line>,
    pub status: Status,
}

pub struct Line {
    pub sku: String,
    pub quantity: u32,
    pub cents: u64,
}

pub enum Status {
    Placed,
    Paid,
    Shipped,
    Cancelled,
}

impl Order {
    pub fn total_cents(&self) -> u64 {
        self.lines.iter().map(|line| line.cents * u64::from(line.quantity)).sum()
    }

    pub fn can_be_cancelled(&self) -> bool {
        matches!(self.status, Status::Placed | Status::Paid)
    }

    pub fn mark_shipped(&mut self) {
        self.status = Status::Shipped;
    }
}

pub fn orders_by_customer(orders: &[Order]) -> HashMap<&str, Vec<&Order>> {
    let mut by_customer: HashMap<&str, Vec<&Order>> = HashMap::new();
    for order in orders {
        by_customer.entry(&order.customer).or_default().push(order);
    }
    by_customer
}

pub fn unpaid_orders_older_than_a_week(orders: &[Order], now: u64) -> Vec<&Order> {
    orders
        .iter()
        .filter(|order| matches!(order.status, Status::Placed) && now - order.id > 7 * 86_400)
        .collect()
}

pub fn restock_report(orders: &[Order]) -> Vec<(String, u32)> {
    let mut sold: HashMap<String, u32> = HashMap::new();
    for line in orders.iter().flat_map(|order| &order.lines) {
        *sold.entry(line.sku.clone()).or_default() += line.quantity;
    }
    let mut report: Vec<(String, u32)> = sold.into_iter().collect();
    report.sort_by(|a, b| b.1.cmp(&a.1));
    report
}
