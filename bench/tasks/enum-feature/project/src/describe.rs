use crate::shape::Shape;

/// The shape in words, like "a circle 2 m across".
pub fn describe(shape: &Shape) -> String {
    match shape {
        Shape::Circle { radius } => format!("a circle {} m across", radius * 2.0),
        Shape::Rect { width, height } => format!("a {width} by {height} m rectangle"),
    }
}
