use shapes::area::area;
use shapes::describe::describe;
use shapes::parse::parse;
use shapes::shape::Shape;

#[test]
fn triangles_work_everywhere() {
    let t = parse("triangle 3 4 5").expect("parses");
    assert_eq!(t, Shape::Triangle { a: 3.0, b: 4.0, c: 5.0 });
    assert!((area(&t) - 6.0).abs() < 1e-9, "Heron's formula");
    assert_eq!(describe(&t), "a triangle with sides 3, 4 and 5 m");
    assert_eq!(parse("triangle 1 1 3"), None, "sides that can't make a triangle");
    assert_eq!(parse("rect 2 3"), Some(Shape::Rect { width: 2.0, height: 3.0 }));
}
