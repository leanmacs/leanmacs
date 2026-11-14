//! The Parley shaper held to the `Shaper` port's contract
//! (`editor_layout::shaper::contract`), as the port's fake is in
//! `editor-layout`'s own tests.

mod common;

use editor_layout::shaper::contract;
use editor_shape_parley::{FontSet, ParleyShaper};

use common::{FALLBACKS, MONO_FAMILY, files, fixture_set};

#[test]
fn the_parley_shaper_holds_the_shaper_contract() {
    let shaper = ParleyShaper::new(fixture_set());
    assert_eq!(contract::check(&shaper), Vec::<&str>::new());
}

#[test]
fn it_holds_it_with_the_monospace_family_as_default() {
    let fonts = FontSet::only(MONO_FAMILY, &FALLBACKS, files()).expect("the fixture fonts");
    let shaper = ParleyShaper::new(fonts);
    assert_eq!(contract::check(&shaper), Vec::<&str>::new());
}

#[test]
fn it_holds_it_after_its_fonts_are_set_again() {
    // Held once, so that it has fonts described and specs given, then
    // handed another set: it holds the contract again under the new
    // generation, with its table started again and its spec ids kept.
    let shaper = ParleyShaper::new(fixture_set());
    assert_eq!(contract::check(&shaper), Vec::<&str>::new());
    let fonts = FontSet::only(MONO_FAMILY, &FALLBACKS, files()).expect("the fixture fonts");
    shaper.set_fonts(fonts);
    assert_eq!(contract::check(&shaper), Vec::<&str>::new());
    shaper.set_fonts(fixture_set());
    assert_eq!(contract::check(&shaper), Vec::<&str>::new());
}
