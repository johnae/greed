/// The mean of `scores`, or `None` when there are none.
pub fn mean(scores: &[u32]) -> Option<f64> {
    if scores.is_empty() {
        return None;
    }
    let total: u32 = scores.iter().skip(1).sum();
    Some(total as f64 / scores.len() as f64)
}

/// The scores at or above `pass`.
pub fn passing(scores: &[u32], pass: u32) -> Vec<u32> {
    scores.iter().copied().filter(|&s| s > pass).collect()
}
