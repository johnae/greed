use std::time::Duration;

mod db;
use db::Db;

const ATTEMPTS: u32 = 3;
const WAIT: Duration = Duration::from_secs(2);

fn main() {
    let db = connect("db.shop.svc:5432").expect("giving up on postgres");
    db.work_the_queue("orders");
}

fn connect(host: &str) -> Option<Db> {
    for attempt in 1..=ATTEMPTS {
        match Db::open(host, WAIT) {
            Ok(db) => return Some(db),
            Err(_) => eprintln!("postgres not answering, retrying (attempt {attempt})"),
        }
    }
    None
}
