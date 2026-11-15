//! The settings a renderer is made with, and how it says what it made of
//! them.

use crate::blend;
use crate::present::Asked;
use crate::{
    Antialiasing, DEFAULT_ATLAS_BUDGET, Masks, PAGE_SIZE, Settings, SubpixelOrder, Weight,
};

#[test]
fn a_kind_of_mask_says_itself_for_a_person() {
    assert_eq!(Masks::Plain.to_string(), "plain masks");
    assert_eq!(
        Masks::Subpixel(SubpixelOrder::Rgb).to_string(),
        "subpixel masks, red first"
    );
    assert_eq!(
        Masks::Subpixel(SubpixelOrder::Bgr).to_string(),
        "subpixel masks, blue first"
    );
}

#[test]
fn the_default_settings_leave_antialiasing_to_the_display_and_hint() {
    // And ask for no presentation: the decision's.
    assert_eq!(
        Settings::default(),
        Settings {
            antialiasing: Antialiasing::Auto,
            hinting: true,
            atlas_budget: DEFAULT_ATLAS_BUDGET,
            weight: Weight::LINEAR,
            presentation: Asked::NOTHING,
        }
    );
    assert_eq!(Antialiasing::default(), Antialiasing::Auto);
    assert_eq!(SubpixelOrder::default(), SubpixelOrder::Rgb);
}

#[test]
fn the_default_weight_is_linear_light_and_the_outline_as_it_is() {
    assert_eq!(Weight::default(), Weight::LINEAR);
    assert_eq!(
        Weight::LINEAR,
        Weight {
            contrast: blend::CONTRAST,
            dilation: 0.0,
        }
    );
}

#[test]
fn the_default_budget_holds_a_page_of_each_kind_several_times_over() {
    // A page of masks is one byte a pixel, and a page of subpixel masks
    // or of colour images four.
    let pixels = u64::from(PAGE_SIZE) * u64::from(PAGE_SIZE);
    assert!(DEFAULT_ATLAS_BUDGET >= 4 * (pixels + 4 * pixels + 4 * pixels));
}
