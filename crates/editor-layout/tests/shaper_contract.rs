//! The published fake of the `Shaper` port held to the port's contract,
//! as every real adapter is in its own crate.

use editor_layout::shaper::contract;
use editor_layout::shaper::fake::CellShaper;

#[test]
fn the_cell_shaper_holds_the_shaper_contract() {
    assert_eq!(
        contract::check(&CellShaper::new(10.0, 16.0)),
        Vec::<&str>::new()
    );
}

#[test]
fn the_cell_shaper_holds_it_at_one_pixel_cells() {
    assert_eq!(
        contract::check(&CellShaper::new(1.0, 1.0)),
        Vec::<&str>::new()
    );
}
