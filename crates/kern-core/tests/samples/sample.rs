/// Adds one.
#[inline]
pub fn add_one(x: u32) -> u32 {
    // the answer
    let y = x + 1;
    if y > 10 {
        return 0;
    }
    println!("{} {}", y, "done\n");
    Some(y).unwrap_or(0)
}
