use crate::shape::Shape;

/// A shape from text like "circle 1.5" or "rect 2 3".
pub fn parse(text: &str) -> Option<Shape> {
    let words: Vec<&str> = text.split_whitespace().collect();
    let numbers: Vec<f64> = words.iter().skip(1).map(|w| w.parse().ok()).collect::<Option<_>>()?;
    match (words.first().copied(), numbers.as_slice()) {
        (Some("circle"), [radius]) => Some(Shape::Circle { radius: *radius }),
        (Some("rect"), [width, height]) => Some(Shape::Rect { width: *width, height: *height }),
        _ => None,
    }
}
