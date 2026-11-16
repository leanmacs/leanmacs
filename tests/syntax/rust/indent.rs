use std::collections::{
    HashMap,
    HashSet,
};

/// A doc comment.
pub struct Point<T>
where
    T: Copy,
{
    x: T,
    y: T,
}

enum Shape {
    Circle(f64),
    Rect { w: f64, h: f64 },
}

impl Shape {
    fn area(&self, scale: f64) -> f64 {
        let base = match self {
            Shape::Circle(r) => 3.14 * r * r,
            Shape::Rect { w, h } => {
                let a = w * h;
                a
            }
        };
        if scale > 1.0 {
            base * scale
        } else if scale < 0.0 {
            0.0
        } else {
            base
        }
    }

    fn generic<
        T: Copy,
    >(t: T) -> T {
        t
    }

    fn long(
        first: u32,
        second: u32,
    ) -> Vec<u32> {
        let v = vec![
            first,
            second,
        ];
        let total = first
            + second;
        let ok = total
            > second;
        let mapped = v
            .iter()
            .map(|x| {
                let y = x + 1;
                y * 2
            })
            .collect::<Vec<_>>();
        call(
            first,
            (second, total),
        );
        mapped
    }
}

fn text() -> &'static str {
    let s = "a
not indented by the rule";
    /* a block
       comment */
    s
}
