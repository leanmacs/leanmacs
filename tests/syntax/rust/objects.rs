fn free(a: u8, b: u8) -> u8 {
    a + b
}

struct Fields {
    x: u8,
    y: u8,
}

struct Unit;

enum Shape {
    Circle(f64),
    Square(f64),
}

trait Area {
    fn area(&self) -> f64;
}

impl Fields {
    fn sum(&self, extra: u8) -> u8 {
        let add = |v| v + extra;
        add(self.x) + call(
            self.y,
            extra,
        )
    }
}

fn call(one: u8, two: u8) -> u8 {
    one + two
}
