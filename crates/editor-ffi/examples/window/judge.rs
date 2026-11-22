//! What is made of a frame's pictures and of the sizes its glyphs are
//! drawn at: each frame's verdict, and what a run finds.

use editor_layout::frame::Frame;
use editor_render::port::Target;

use crate::scene::POINTS;

/// How far any channel of any pixel the window's surface holds may be from
/// the headless renderer's: 3 of 255, as the renderer's own check on a real
/// adapter allows (`crates/editor-render-wgpu/examples/gpu.rs`).
const TOLERANCE: u8 = 3;

/// What a presented frame's picture was found to be.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Picture {
    /// It was compared with the headless renderer's: how many pixels it
    /// has, how many differ, and the largest difference of any channel.
    Compared {
        /// The pixels of the picture.
        pixels: usize,
        /// The pixels that differ at all.
        differing: usize,
        /// The largest difference of any channel.
        worst: u8,
    },
    /// It is not the size of its target.
    WrongSize(u32, u32),
    /// There is none: the window's surface does not let its texture be
    /// copied from.
    NotCopied,
    /// It could not be read back, from a surface that lets its texture be
    /// copied from: why.
    Unread(String),
}

/// What is made of `pictures`, what each frame presented was found to be,
/// in order, in a run that reads pictures back when `read` says so and
/// requires each to be compared when `require` does. A run that reads
/// none says so, once, and fails for none: nothing was found of any.
pub fn pictured(pictures: &[Picture], read: bool, require: bool) -> Findings {
    if !read {
        return Findings {
            lines: vec![
                "pictures were not read back (--no-picture): the picture was not checked in this run"
                    .to_owned(),
            ],
            failures: Vec::new(),
        };
    }
    let mut found = Findings::default();
    for (number, picture) in pictures.iter().enumerate() {
        let verdict = judged(number + 1, picture, require);
        found.lines.extend(verdict.line);
        found.failures.extend(verdict.failure);
    }
    found
}

/// What is found of a frame's picture without comparing it, when it cannot
/// be compared: a surface that is not copied from (`copies` says which it
/// is) has no picture, and one that is, and whose picture the renderer
/// then refused to read (`refused` says why), could not be read. `None`
/// when there is a picture to compare.
pub fn uncompared(copies: bool, refused: Option<&str>) -> Option<Picture> {
    if !copies {
        return Some(Picture::NotCopied);
    }
    refused.map(|reason| Picture::Unread(reason.to_owned()))
}

/// What is made of one frame's picture.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Verdict {
    /// What is printed of it, when anything is.
    pub line: Option<String>,
    /// Why the run fails by it, when it does.
    pub failure: Option<String>,
}

/// What is made of `picture`, the picture of the frame presented
/// `number`th, in a run that requires a comparison when `require_picture`
/// says so.
fn judged(number: usize, picture: &Picture, require_picture: bool) -> Verdict {
    match picture {
        Picture::Compared {
            pixels,
            differing,
            worst,
        } => Verdict {
            line: Some(format!(
                "frame {number}: read back from the surface, {differing} of {pixels} pixels differ from the headless renderer's, the worst by {worst} of 255"
            )),
            failure: (*worst > TOLERANCE).then(|| {
                format!(
                    "frame {number}'s picture differs by {worst} of 255, past the tolerance of {TOLERANCE}"
                )
            }),
        },
        Picture::WrongSize(width, height) => Verdict {
            line: None,
            failure: Some(format!(
                "frame {number}'s picture is {width} by {height}, not the size of its target"
            )),
        },
        // What a surface offers is not a failure of the window, unless the
        // run is one that must compare: in the container the surface is
        // known to let its texture be copied from.
        Picture::NotCopied => Verdict {
            line: Some(format!(
                "frame {number}: the surface does not let its texture be copied from, so its picture is not compared"
            )),
            failure: require_picture.then(|| {
                format!(
                    "frame {number}'s picture was not compared, and this run requires it (--require-picture): the surface does not let its texture be copied from"
                )
            }),
        },
        // A read that failed is a failure wherever it happens: the surface
        // said its texture could be copied from.
        Picture::Unread(reason) => Verdict {
            line: None,
            failure: Some(format!(
                "frame {number}'s picture could not be read back: {reason}"
            )),
        },
    }
}

/// The sizes the glyphs of `frame` are drawn at, in pixels, smallest first
/// and each once: the size of each font a glyph of a row or of a status
/// row names. A font of the frame's table that no glyph names is not
/// among them: the table is the shaper's, and keeps the fonts of every
/// scale it was asked at. A glyph that names no font of the table has no
/// size.
pub fn drawn_at(frame: &Frame) -> Vec<f32> {
    let lines = frame.views.iter().flat_map(|view| {
        let rows = view.rows.iter().map(|row| &row.line);
        rows.chain(view.status.iter().map(|status| &status.line))
    });
    let mut sizes: Vec<f32> = lines
        .flat_map(|line| line.glyphs.iter())
        .filter_map(|glyph| frame.fonts.get(usize::try_from(glyph.font.0).ok()?))
        .map(|font| font.size)
        .collect();
    sizes.sort_by(f32::total_cmp);
    sizes.dedup();
    sizes
}

/// `items` as a person lists them: `a`, `a and b`, `a, b and c`; nothing
/// for none.
pub fn listed(items: &[String]) -> String {
    match items {
        [] => String::new(),
        [one] => one.clone(),
        [first @ .., last] => format!("{} and {last}", first.join(", ")),
    }
}

/// What is made of the sizes `sizes` that the glyphs of the frame published
/// `number`th are drawn at ([`drawn_at`]), when it was laid out for a
/// window that says it is `window`.
///
/// The fixture states one size, [`POINTS`] points, and a point is as many
/// pixels as the window's scale. So the glyphs must be drawn at one size,
/// that many pixels to within a 64th of one, which is what a length is
/// kept in. This is the whole path from the scale a window says, through
/// the layout that was told it, to the size the shaper made its glyphs at:
/// a layout that was not told the scale fails here.
pub fn laid_out(number: usize, window: Target, sizes: &[f32]) -> Verdict {
    let Target {
        width,
        height,
        scale,
    } = window;
    let laid = format!("frame {number} is laid out for {width} by {height} at scale {scale}");
    match sizes {
        [] => Verdict {
            line: Some(format!("{laid}: it has no glyph")),
            failure: Some(format!(
                "frame {number} has no glyph, so nothing says what size {POINTS} points are drawn at"
            )),
        },
        [size] => {
            let expected = POINTS as f32 * scale;
            Verdict {
                line: Some(format!("{laid}: {POINTS} points are {size} pixels")),
                failure: ((size - expected).abs() > 1.0 / 64.0).then(|| {
                    format!(
                        "frame {number} is laid out for a window at scale {scale}, where {POINTS} points are {expected} pixels, and its glyphs are drawn at {size} pixels"
                    )
                }),
            }
        }
        several => {
            let sizes: Vec<String> = several.iter().map(f32::to_string).collect();
            let sizes = listed(&sizes);
            Verdict {
                line: Some(format!("{laid}: its glyphs are drawn at {sizes} pixels")),
                failure: Some(format!(
                    "frame {number}'s glyphs are drawn at {sizes} pixels, and the fixture states one size, {POINTS} points"
                )),
            }
        }
    }
}

/// What is made of something the example saw: the lines to print of it,
/// and why the run fails by it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Findings {
    /// What is printed.
    pub lines: Vec<String>,
    /// Why the run fails.
    pub failures: Vec<String>,
}

/// What the example decides of what it saw, with no window: these run in
/// the gate.
#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use editor_layout::face::Color;
    use editor_layout::frame::{Frame, FrameRow, StatusRow, ViewFrame};
    use editor_layout::scene::{Rect, ViewId};
    use editor_layout::shaper::{Glyph, ResolvedFont, ResolvedFontId, VisualLine};
    use editor_render::port::Target;

    use super::{
        Findings, Picture, TOLERANCE, Verdict, drawn_at, judged, laid_out, pictured, uncompared,
    };
    use crate::testing::SMALL;

    /// A line of one glyph for each of `fonts`, each naming that entry of
    /// its frame's table.
    fn line_in(fonts: &[u32]) -> Arc<VisualLine> {
        let glyphs: Vec<Glyph> = (0..)
            .zip(fonts)
            .map(|(at, font)| Glyph {
                id: 1,
                font: ResolvedFontId(*font),
                cluster: at,
                x: at as f32 * 10.0,
                dx: 0.0,
                dy: 0.0,
                advance: 10.0,
            })
            .collect();
        Arc::new(VisualLine {
            bytes: 0..glyphs.len(),
            width: glyphs.len() as f32 * 10.0,
            glyphs,
            height: 16.0,
            baseline: 12.0,
        })
    }

    /// A frame written by hand, of one view: a row for each of `rows` and
    /// a status row of `status` when there is one, each a line of one
    /// glyph for each font it lists ([`line_in`]); and a table of one font
    /// for each of `sizes`, of that size.
    fn frame_in(rows: &[&[u32]], status: Option<&[u32]>, sizes: &[f32]) -> Frame {
        let white = Color::rgb(0xff, 0xff, 0xff);
        let rows = rows
            .iter()
            .map(|fonts| {
                FrameRow::text_row(0.0, 0.0, 0..fonts.len(), line_in(fonts), Vec::new(), 0)
            })
            .collect();
        let status = status.map(|fonts| StatusRow {
            y: 0.0,
            height: 16.0,
            baseline: 12.0,
            line: line_in(fonts),
            runs: Vec::new(),
            background: white,
            boxes: Vec::new(),
            hash: 0,
        });
        let fonts = sizes
            .iter()
            .map(|size| ResolvedFont {
                data: Arc::new([0_u8; 0]),
                file: 0,
                index: 0,
                size: *size,
                coords: Vec::new(),
                embolden: false,
                skew: None,
            })
            .collect();
        Frame {
            ground: white,
            views: vec![ViewFrame {
                id: ViewId(1),
                rect: Rect::default(),
                background: white,
                rows,
                status,
                cursors: Vec::new(),
                selections: Vec::new(),
                selection: white,
            }],
            generation: 0,
            fonts,
            dividers: Vec::new(),
        }
    }

    #[test]
    fn the_sizes_a_frames_glyphs_are_drawn_at_are_those_of_the_fonts_they_name() {
        // The table of a shaper that has been asked for fonts at several
        // scales: within a generation it only grows, so the fonts of an
        // earlier scale stay in it, and a frame names the ones it uses.
        let table = [16.0, 14.0, 28.0, 21.0];
        // One size, named by every row and by the status row.
        let frame = frame_in(&[&[2, 2], &[2]], Some(&[2]), &table);
        assert_eq!(drawn_at(&frame), [28.0]);
        // Several: smallest first, each once, the status row's among them.
        let frame = frame_in(&[&[3, 1], &[1]], Some(&[2]), &table);
        assert_eq!(drawn_at(&frame), [14.0, 21.0, 28.0]);
        // A view with no status row.
        assert_eq!(drawn_at(&frame_in(&[&[0]], None, &table)), [16.0]);
        // A frame with no glyph is drawn at no size, whatever its table
        // holds, and a glyph that names no font of the table has no size.
        let none: [f32; 0] = [];
        assert_eq!(drawn_at(&frame_in(&[&[]], None, &table)), none);
        assert_eq!(drawn_at(&frame_in(&[&[9]], None, &table)), none);
        assert_eq!(drawn_at(&Frame::default()), none);
    }

    #[test]
    fn fourteen_points_at_a_scale_are_that_many_pixels_and_any_other_size_fails_the_run() {
        let at = |scale: f32| Target {
            width: 1600,
            height: 1200,
            scale,
        };
        let passes = |line: &str| Verdict {
            line: Some(line.to_owned()),
            failure: None,
        };
        assert_eq!(
            laid_out(1, at(2.0), &[28.0]),
            passes("frame 1 is laid out for 1600 by 1200 at scale 2: 14 points are 28 pixels")
        );
        assert_eq!(
            laid_out(3, SMALL, &[14.0]),
            passes("frame 3 is laid out for 400 by 300 at scale 1: 14 points are 14 pixels")
        );
        // A fractional scale, and a size that is within a 64th of a pixel
        // of the product: a length is kept in 64ths.
        assert_eq!(
            laid_out(2, at(1.25), &[17.5]),
            passes("frame 2 is laid out for 1600 by 1200 at scale 1.25: 14 points are 17.5 pixels")
        );
        assert_eq!(laid_out(2, at(1.3333), &[18.671_875]).failure, None);
        assert_eq!(laid_out(2, at(2.0), &[28.0 + 1.0 / 64.0]).failure, None);

        // Any other size fails: a layout that was never told the scale
        // draws 14 points at 14 pixels on a window at scale 2.
        assert_eq!(
            laid_out(1, at(2.0), &[14.0]),
            Verdict {
                line: Some(
                    "frame 1 is laid out for 1600 by 1200 at scale 2: 14 points are 14 pixels"
                        .to_owned()
                ),
                failure: Some(
                    "frame 1 is laid out for a window at scale 2, where 14 points are 28 pixels, and its glyphs are drawn at 14 pixels"
                        .to_owned()
                ),
            }
        );
        // Past a 64th, on either side.
        for size in [28.0 + 2.0 / 64.0, 28.0 - 2.0 / 64.0] {
            assert!(laid_out(1, at(2.0), &[size]).failure.is_some(), "{size}");
        }
        // The fixture states one size: a frame drawn at several fails, and
        // so does one with no glyph to read a size from.
        assert_eq!(
            laid_out(1, at(2.0), &[14.0, 21.0, 28.0]),
            Verdict {
                line: Some(
                    "frame 1 is laid out for 1600 by 1200 at scale 2: its glyphs are drawn at 14, 21 and 28 pixels"
                        .to_owned()
                ),
                failure: Some(
                    "frame 1's glyphs are drawn at 14, 21 and 28 pixels, and the fixture states one size, 14 points"
                        .to_owned()
                ),
            }
        );
        assert_eq!(
            laid_out(1, at(2.0), &[]),
            Verdict {
                line: Some(
                    "frame 1 is laid out for 1600 by 1200 at scale 2: it has no glyph".to_owned()
                ),
                failure: Some(
                    "frame 1 has no glyph, so nothing says what size 14 points are drawn at"
                        .to_owned()
                ),
            }
        );
    }

    #[test]
    fn a_run_that_reads_no_picture_says_so_and_fails_for_none() {
        // Nothing was read, so nothing was found of any picture.
        assert_eq!(
            pictured(&[], false, false),
            Findings {
                lines: vec![
                    "pictures were not read back (--no-picture): the picture was not checked in this run"
                        .to_owned()
                ],
                failures: Vec::new(),
            }
        );
        // A run that reads them says what each was found to be, as before,
        // and nothing of this.
        let compared = Picture::Compared {
            pixels: 100,
            differing: 7,
            worst: TOLERANCE + 1,
        };
        let pictures = [compared.clone(), Picture::NotCopied];
        for require in [false, true] {
            let found = pictured(&pictures, true, require);
            let each = [
                judged(1, &compared, require),
                judged(2, &Picture::NotCopied, require),
            ];
            assert_eq!(
                found.lines,
                each.iter()
                    .filter_map(|verdict| verdict.line.clone())
                    .collect::<Vec<_>>()
            );
            assert_eq!(
                found.failures,
                each.iter()
                    .filter_map(|verdict| verdict.failure.clone())
                    .collect::<Vec<_>>()
            );
            assert_eq!(found.lines.len(), 2);
            assert_eq!(found.failures.len(), if require { 2 } else { 1 });
        }
        assert_eq!(pictured(&[], true, true), Findings::default());
    }

    #[test]
    fn a_surface_that_is_not_copied_from_has_no_picture_and_a_read_that_was_refused_is_unread() {
        // Whatever the renderer then said of reading it.
        assert_eq!(uncompared(false, None), Some(Picture::NotCopied));
        assert_eq!(
            uncompared(false, Some("not copied from")),
            Some(Picture::NotCopied)
        );
        assert_eq!(
            uncompared(true, Some("the copy was refused")),
            Some(Picture::Unread("the copy was refused".to_owned()))
        );
        // Read: there is a picture to compare.
        assert_eq!(uncompared(true, None), None);
    }

    #[test]
    fn a_picture_within_the_tolerance_passes_and_one_past_it_fails() {
        let compared = |worst| Picture::Compared {
            pixels: 100,
            differing: 7,
            worst,
        };
        for require_picture in [false, true] {
            let within = judged(2, &compared(TOLERANCE), require_picture);
            assert_eq!(
                within,
                Verdict {
                    line: Some(format!(
                        "frame 2: read back from the surface, 7 of 100 pixels differ from the headless renderer's, the worst by {TOLERANCE} of 255"
                    )),
                    failure: None,
                }
            );
            let past = judged(2, &compared(TOLERANCE + 1), require_picture);
            assert!(past.line.is_some(), "{past:?}");
            assert_eq!(
                past.failure,
                Some(format!(
                    "frame 2's picture differs by {} of 255, past the tolerance of {TOLERANCE}",
                    TOLERANCE + 1
                ))
            );
        }
    }

    #[test]
    fn a_picture_of_the_wrong_size_fails() {
        for require_picture in [false, true] {
            assert_eq!(
                judged(1, &Picture::WrongSize(0, 0), require_picture).failure,
                Some("frame 1's picture is 0 by 0, not the size of its target".to_owned())
            );
        }
    }

    #[test]
    fn a_picture_that_could_not_be_read_back_fails_whether_or_not_one_is_required() {
        let unread = Picture::Unread("the copy was refused".to_owned());
        for require_picture in [false, true] {
            assert_eq!(
                judged(3, &unread, require_picture).failure,
                Some("frame 3's picture could not be read back: the copy was refused".to_owned()),
                "required: {require_picture}"
            );
        }
    }

    #[test]
    fn a_surface_that_is_not_copied_from_fails_only_a_run_that_requires_the_picture() {
        let said = Some(
            "frame 1: the surface does not let its texture be copied from, so its picture is not compared"
                .to_owned(),
        );
        assert_eq!(
            judged(1, &Picture::NotCopied, false),
            Verdict {
                line: said.clone(),
                failure: None,
            }
        );
        assert_eq!(
            judged(1, &Picture::NotCopied, true),
            Verdict {
                line: said,
                failure: Some(
                    "frame 1's picture was not compared, and this run requires it (--require-picture): the surface does not let its texture be copied from"
                        .to_owned()
                ),
            }
        );
    }
}
