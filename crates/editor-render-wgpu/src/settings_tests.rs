//! The settings a renderer is made with.

use crate::{Antialiasing, DEFAULT_ATLAS_BUDGET, PAGE_SIZE, Settings, SubpixelOrder};

#[test]
fn the_default_settings_leave_antialiasing_to_the_display_and_hint() {
    assert_eq!(
        Settings::default(),
        Settings {
            antialiasing: Antialiasing::Auto,
            hinting: true,
            atlas_budget: DEFAULT_ATLAS_BUDGET,
        }
    );
    assert_eq!(Antialiasing::default(), Antialiasing::Auto);
    assert_eq!(SubpixelOrder::default(), SubpixelOrder::Rgb);
}

#[test]
fn the_default_budget_holds_a_page_of_each_kind_several_times_over() {
    // A page of masks is one byte a pixel, and a page of subpixel masks
    // or of colour images four.
    let pixels = u64::from(PAGE_SIZE) * u64::from(PAGE_SIZE);
    assert!(DEFAULT_ATLAS_BUDGET >= 4 * (pixels + 4 * pixels + 4 * pixels));
}
