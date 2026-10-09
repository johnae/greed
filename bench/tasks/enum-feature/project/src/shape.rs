/// A shape, its sizes in metres.
#[derive(Debug, Clone, PartialEq)]
pub enum Shape {
    Circle { radius: f64 },
    Rect { width: f64, height: f64 },
}
