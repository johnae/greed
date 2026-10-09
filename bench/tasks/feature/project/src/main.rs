use stats::stats::mean;

fn main() {
    let values: Vec<f64> = std::env::args().skip(1).filter_map(|a| a.parse().ok()).collect();
    match mean(&values) {
        Some(m) => println!("mean {m}"),
        None => println!("no values"),
    }
}
