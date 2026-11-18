//! The fixture the window draws: its scene, its text and the size of it,
//! and the fonts it is laid out in, the fixture fonts compiled in or a
//! family of the machine's.

use editor_ffi::render::target;
use editor_layout::face::{Color, Face, FaceDef};
use editor_layout::scene::{Rect, Scene, StatusField};
use editor_layout::shaper::Length;
use editor_platform::Resize;
use editor_shape_parley::FontSet;

/// Noto Sans: the default family.
const SANS: &[u8] = include_bytes!("../../../../tests/fonts/NotoSans-Regular.subset.ttf");
/// Noto Sans Hebrew, a fallback.
const HEBREW: &[u8] = include_bytes!("../../../../tests/fonts/NotoSansHebrew-Regular.ttf");
/// Noto Sans JP, a fallback.
const JP: &[u8] = include_bytes!("../../../../tests/fonts/NotoSansJP-Regular.subset.otf");

/// The text of the fixture: a ligature (`fi`), a right-to-left run and a
/// character of the CJK fallback, in two rows.
const TEXT: &str = "fine שלום 日\nthe window draws this";

/// The size the fixture's default face states, in points: what a person
/// compares with the same size in another app.
pub const POINTS: u32 = 14;

/// The machine's own name for the family `name`, of `families`, the
/// families it has: the one that is `name` whatever the case of its
/// letters. The error is that it has none, for a person.
fn family_of(name: &str, families: &[String]) -> Result<String, String> {
    families
        .iter()
        .find(|family| family.eq_ignore_ascii_case(name))
        .cloned()
        .ok_or_else(|| {
            format!(
                "this machine has no font family named {name}, of its {} families",
                families.len()
            )
        })
}

/// The fonts the fixture is laid out in, and the family its default face
/// names: the fixture fonts, compiled in, and no family; or, when `family`
/// is given, the fonts of this machine and that family as the machine
/// names it. The error is why there are none: a family the machine has
/// not is one.
pub fn fonts(family: Option<&str>) -> Result<(FontSet, Option<String>), String> {
    let Some(name) = family else {
        let files: Vec<Vec<u8>> = [SANS, HEBREW, JP]
            .iter()
            .map(|bytes| bytes.to_vec())
            .collect();
        let fallbacks = ["Noto Sans Hebrew", "Noto Sans JP"];
        let fonts = FontSet::only("Noto Sans", &fallbacks, files)
            .map_err(|error| format!("the fixture fonts: {error}"))?;
        return Ok((fonts, None));
    };
    #[expect(
        clippy::disallowed_methods,
        reason = "a person who asks for a family of this machine's fonts (--family) is the one caller: no test and no other run reads the machine's fonts"
    )]
    let fonts = FontSet::system();
    let family = family_of(name, &fonts.families())?;
    Ok((fonts, Some(family)))
}

/// The fixture scene in a window of `size`: [`TEXT`] in one view that
/// fills it, a selection with its cursor, and a status row, in a default
/// face of [`POINTS`] points, and of the family `family` when there is
/// one. Its rectangle and the size its status row reads are physical
/// pixels; the face's size is the one length here that is not.
pub fn scene(size: Resize, family: Option<&str>) -> Scene {
    let target = target(size);
    let rect = Rect {
        x: 0,
        y: 0,
        width: target.width,
        height: target.height,
    };
    let named = |name: &str, face: Face| FaceDef {
        name: name.to_owned(),
        face,
    };
    let rgb = |red: u8, green: u8, blue: u8| Some(Color::rgb(red, green, blue));
    let mut scene = Scene::of_text(TEXT, rect).selecting(2..7);
    scene.faces = Some(vec![
        named(
            "default",
            Face {
                family: family.map(str::to_owned),
                // In points: layout puts it at the window's scale.
                size: Some(Length::pixels(POINTS)),
                foreground: rgb(0x20, 0x20, 0x20),
                background: rgb(0xf8, 0xf8, 0xf8),
                ..Face::default()
            },
        ),
        named(
            "selection",
            Face {
                background: rgb(0xc0, 0xd8, 0xff),
                ..Face::default()
            },
        ),
        named(
            "mode-line",
            Face {
                foreground: rgb(0xf0, 0xf0, 0xf0),
                background: rgb(0x40, 0x40, 0x40),
                ..Face::default()
            },
        ),
    ]);
    scene.views[0].status = vec![StatusField {
        text: format!("window  {} by {}", size.width, size.height),
        face: "mode-line".to_owned(),
        ..StatusField::default()
    }];
    scene
}

/// What the example decides of what it saw, with no window: these run in
/// the gate.
#[cfg(test)]
mod tests {
    use super::family_of;

    #[test]
    fn a_family_is_one_the_machine_has_by_its_own_name_for_it_and_any_other_is_refused() {
        let families = ["Courier", "Helvetica Neue", "Menlo"].map(str::to_owned);
        assert_eq!(family_of("Menlo", &families), Ok("Menlo".to_owned()));
        // Whatever the case it was asked in, it is the machine's name.
        assert_eq!(
            family_of("helvetica neue", &families),
            Ok("Helvetica Neue".to_owned())
        );
        // One it has not is said, with how many it has.
        assert_eq!(
            family_of("Noto Sans", &families),
            Err("this machine has no font family named Noto Sans, of its 3 families".to_owned())
        );
        // A part of a name is not the name.
        assert!(family_of("Helvetica", &families).is_err());
        assert!(family_of("Menlo", &[]).is_err());
    }
}
