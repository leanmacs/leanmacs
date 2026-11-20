//! The painter: a frame and a target in, the list of quads to draw out.
//!
//! This is everything about drawing a frame that does not depend on what
//! draws it. The painter keeps the glyph cache and, through
//! `editor-render`'s row cache, the quads of each row of the frame it last
//! painted; a device behind it only blends the quads it is handed, in
//! order, from the atlas's pages.
//!
//! # What is drawn, in order
//!
//! First the frame's dividers ([`Frame::dividers`]), each its rectangle
//! filled in its colour, clipped to the target, so a view drawn over one,
//! a float's, covers it. Then for each view, clipped to its rectangle and
//! to the target:
//!
//! 1. its background;
//! 2. the background of each run of each text row, where it is not the
//!    view's;
//! 3. its selection areas;
//! 4. the glyphs of each text row;
//! 5. the underlines and the strike-throughs of each text row;
//! 6. its status row, the same way, over the status row's own background
//!    across the view, with the box of each of its fields (its padding
//!    and its text) filled in the field's colour where that is not the
//!    row's, under its runs' backgrounds;
//! 7. its cursors.
//!
//! Nothing is drawn outside a view or a divider: the device clears the
//! target first.
//!
//! # Where a glyph goes
//!
//! A glyph's image is placed by the frame's own numbers and no others. Its
//! place across is its `x` plus its `dx`, from its row's left, rounded to
//! a quarter of a pixel: the whole pixels place the quad and the quarters
//! pick the image ([`bin_of`]). A row's left is its view's left edge plus
//! the row's `x` (a padded view's padding across), rounded to a pixel as
//! its top is, so a fractional padding draws on a whole pixel and the
//! glyph's quarters are its own. Its place down is its row's
//! top, rounded to a pixel, plus the row's baseline plus its `dy`, rounded
//! to a pixel: a baseline is a whole pixel. The image's own offsets from
//! that point are the rasteriser's.
//!
//! A glyph is painted with the run that holds its cluster. A glyph that
//! draws several characters across a change of paint, a ligature, has one
//! cluster, the first of them: it is drawn whole in that paint.
//!
//! # What is kept per row
//!
//! A row's quads are built relative to the row's own start (its left and
//! its own top), so they are the same wherever the row is,
//! and kept by the row's content hash. A row seen again costs nothing but
//! adding its position to its quads: the rasteriser is not asked.
//! Cursors and selections are not part of any row and are made anew each
//! time.
//!
//! Each row pins the glyph images it draws, and lets them go when it is
//! dropped ([`glyphs`](crate::glyphs), "In use is never evicted").
//!
//! A rasteriser handed over after a paint ([`Painter::set_rasterizer`])
//! empties the glyph cache and the rows kept: the next paint builds every
//! row again.
//!
//! # What a paint answers
//!
//! What it did, counted: the rows it built, the rows it took from what
//! was kept, and what the glyph cache did for it. Presenting is the
//! device's, and a device may refuse a draw when the paint is already
//! done. Its adapter then says so ([`Painter::refused`]), and the next
//! paint answers for both as if the two were one draw: the counts are
//! added, and a row the refused draw built is a row built, not a row
//! reused, whichever frame is painted next. So the work is counted once,
//! by the draw that presents, and a frame presented at its second attempt
//! is answered for as at its first. A row built for a frame that was
//! never presented is counted as built all the same, though the frame
//! presented does not show it.
//!
//! # What the scale changes
//!
//! A frame is in physical pixels: layout has already multiplied a theme's
//! lengths by the scale it was told (`editor_layout::face`, "Units"), so
//! the painter multiplies nothing in a frame by the scale, and nothing is
//! scaled twice. The scale of the target changes two things, both the
//! painter's own:
//!
//! - what the painter itself sizes is as many pixels thick as the scale,
//!   rounded, and never less than one: an underline, a strike-through, a
//!   bar cursor, an underline cursor and the edge of a hollow cursor;
//! - the kind of mask glyph images are asked in ([`stripes`]), which
//!   [`Painter::masks`] says of the last paint.
//!
//! Rows built at one scale are built again at another. A frame laid out
//! at one scale may be painted once for a target at another, between a
//! window saying its new scale and the frame laid out for it arriving:
//! its glyphs are the size they were laid out at, and its lines and masks
//! are the target's.
//!
//! # What is not tuned
//!
//! Where an underline and a strike-through sit (the frame carries no
//! metric for either): an underline is one thickness below the baseline,
//! a strike-through three tenths of the font's size above it. A curly
//! underline is a stepped line.

use std::collections::HashSet;

use editor_layout::face::{Color, Paint, UnderlineStyle};
use editor_layout::frame::{CursorBox, Frame, ViewFrame};
use editor_layout::scene::CursorShape;
use editor_layout::shaper::ResolvedFont;
use editor_raster::luminance_bucket;
use editor_render::port::{Drawn, Target};
use editor_render::rows::{RowCache, RowRef, shown};

use crate::atlas::Atlas;
use crate::blend::stripes;
use crate::glyphs::{GlyphCache, GlyphImage, GlyphKey, GlyphRequest, Kind, Rasterize, bin_of};
use crate::quads::{Clip, Quad, QuadKind, pixel};
use crate::{Antialiasing, Masks, Settings, SubpixelOrder};

/// How many pixels thick a line the painter sizes is at `scale`: the
/// scale rounded, and never less than one.
pub fn thickness(scale: f32) -> u32 {
    (scale.round() as u32).max(1)
}

/// What the painter keeps for a row: its quads, relative to the row's
/// start, and the glyph images it pins.
#[derive(Debug, Default)]
pub struct RowQuads {
    /// The box of each field of a status row and then the background of
    /// each run, in order across the row: its left edge, its width and its
    /// colour. Its height is the row's, which is set when the row is
    /// placed.
    backgrounds: Vec<Quad>,
    /// The glyphs.
    glyphs: Vec<Quad>,
    /// The underlines and the strike-throughs.
    lines: Vec<Quad>,
    /// The glyph images the row took from the cache.
    pins: Vec<GlyphKey>,
}

/// A rasteriser whose subpixel masks are in a display's stripe order.
struct Ordered<'a, Z> {
    /// The rasteriser, which gives red, green and blue in that order.
    inner: &'a mut Z,
    /// The order of the display's stripes.
    order: Option<SubpixelOrder>,
}

impl<Z: Rasterize> Rasterize for Ordered<'_, Z> {
    fn rasterize(&mut self, request: &GlyphRequest<'_>) -> Option<GlyphImage> {
        let mut image = self.inner.rasterize(request)?;
        if image.kind == Kind::Subpixel && self.order == Some(SubpixelOrder::Bgr) {
            for pixel in image.data.as_chunks_mut::<4>().0 {
                pixel.swap(0, 2);
            }
        }
        Some(image)
    }

    fn by_luminance(&self) -> bool {
        self.inner.by_luminance()
    }
}

/// A stretch of a row's glyphs, next to each other, in one paint.
struct Span {
    /// Its left edge, from the row's start.
    start: f32,
    /// Its right edge.
    end: f32,
    /// What it is painted with.
    paint: Paint,
    /// The size of the font of its first glyph.
    size: f32,
}

/// The painter: the glyph cache, the rows kept, and the quads of the
/// frame last painted.
pub struct Painter<Z> {
    /// What makes glyph images.
    rasterizer: Z,
    /// Whether outlines are fitted to the pixel grid.
    hint: bool,
    /// How glyphs are antialiased.
    antialiasing: Antialiasing,
    /// Whether the device behind the painter blends by a coverage for
    /// each channel.
    per_channel: bool,
    /// The glyph images.
    glyphs: GlyphCache,
    /// The quads of each row of the frame last painted.
    rows: RowCache<RowQuads>,
    /// The generation of the frame last painted.
    generation: Option<u64>,
    /// The kind of mask the last paint asked its glyph images in.
    masks: Option<Masks>,
    /// The glyphs of the frame last painted that name no font of it.
    unknown: u64,
    /// The quads of the frame last painted, in drawing order.
    quads: Vec<Quad>,
    /// What the last paint answered, until the next: what is carried if
    /// its draw is refused.
    last: Option<Unpresented>,
    /// What was painted for draws that were refused, since the last draw
    /// that was not: the next paint answers for it.
    carried: Unpresented,
}

/// What was painted and not yet presented: the work, and the rows it
/// built.
#[derive(Debug, Default)]
struct Unpresented {
    /// What was done, counted.
    done: Drawn,
    /// The content hashes of the rows that were built.
    built: HashSet<u64>,
}

impl<Z: Rasterize> Painter<Z> {
    /// A painter that has painted nothing, for a device that blends by a
    /// coverage for each channel (`per_channel`) or one that cannot.
    /// Glyph images are made by `rasterizer`, hinted and antialiased as
    /// `settings` says: as subpixel masks or as plain ones by the scale
    /// of each target ([`stripes`]). The atlas's pages are `page_size`
    /// pixels across and down and may come to the settings' budget.
    pub fn new(rasterizer: Z, settings: &Settings, per_channel: bool, page_size: u32) -> Self {
        Self {
            rasterizer,
            hint: settings.hinting,
            antialiasing: settings.antialiasing,
            per_channel,
            glyphs: GlyphCache::new(page_size, settings.atlas_budget),
            rows: RowCache::new(),
            generation: None,
            masks: None,
            unknown: 0,
            quads: Vec::new(),
            last: None,
            carried: Unpresented::default(),
        }
    }

    /// Paints `frame` for `target`: makes [`Painter::quads`] the list to
    /// draw, and says what that cost, with what the paints before it cost
    /// whose draws were refused ([`Painter::refused`]). The answer's
    /// `presented` is `false`: presenting is the device's.
    pub fn paint(&mut self, frame: &Frame, target: Target) -> Drawn {
        let before = self.glyphs.stats();
        // What the refused draws before this one did: this paint answers
        // for it, and is carried with it if its own draw is refused.
        let Unpresented {
            done: carried,
            mut built,
        } = std::mem::take(&mut self.carried);
        // A font id means another font under another generation: nothing
        // kept by one is of use, and the rows that pinned it are dropped
        // below without being unpinned, since their keys now name the
        // new generation's images.
        let stale = self.generation.is_some_and(|held| held != frame.generation);
        if stale {
            self.glyphs.clear();
        }
        self.generation = Some(frame.generation);
        self.glyphs.trim();
        self.unknown = 0;

        let (rasterizer, glyphs, unknown) =
            (&mut self.rasterizer, &mut self.glyphs, &mut self.unknown);
        // The kind of mask asked for is fixed for a scale, and rows are
        // built again at another scale: a kept row never holds the other
        // kind.
        let order = stripes(self.antialiasing, target.scale, self.per_channel);
        self.masks = Some(order.map_or(Masks::Plain, Masks::Subpixel));
        let mut ordered = Ordered {
            inner: rasterizer,
            order,
        };
        let (hint, subpixel) = (self.hint, order.is_some());
        let tinted = ordered.by_luminance();
        let line = thickness(target.scale);
        let reuse = self.rows.update(frame, target.scale, |row| {
            built.insert(row.hash);
            build_row(
                &row,
                &frame.fonts,
                line,
                &mut |key, font| glyphs.get(key, font, hint, &mut ordered),
                Asked { subpixel, tinted },
                unknown,
            )
        });
        if !stale {
            for row in &reuse.dropped {
                for key in &row.pins {
                    self.glyphs.unpin(*key);
                }
            }
        }

        self.quads.clear();
        let whole = Clip::of(0, 0, target.width, target.height);
        for fill in &frame.dividers {
            let rect = fill.rect;
            self.quads.extend(
                Quad::fill(
                    rect.x as i32,
                    rect.y as i32,
                    rect.width,
                    rect.height,
                    fill.color,
                )
                .clipped(whole),
            );
        }
        for view in &frame.views {
            place_view(view, &self.rows, whole, line, &mut self.quads);
        }

        // A row a refused draw built is built, not reused, in the draw
        // that presents it: the rows reused are those of the frame that
        // were held before any of that. With nothing carried they are the
        // rows this paint did not build. A row built and no longer shown
        // is forgotten: shown again, it is built again.
        let reused = if carried.rows_rebuilt == 0 {
            reuse.reused
        } else {
            let rows: HashSet<u64> = shown(frame).map(|row| row.hash).collect();
            built.retain(|hash| rows.contains(hash));
            (rows.len() - built.len()) as u64
        };
        let after = self.glyphs.stats();
        let done = Drawn {
            presented: false,
            // Whether the target can be seen is the device's to find.
            hidden: false,
            rows_rebuilt: carried.rows_rebuilt + reuse.rebuilt,
            rows_reused: reused,
            glyphs_rasterised: carried.glyphs_rasterised + after.rasterised - before.rasterised,
            glyphs_reused: carried.glyphs_reused + after.reused - before.reused,
            glyphs_evicted: carried.glyphs_evicted + after.evicted - before.evicted,
            glyphs_skipped: carried.glyphs_skipped + after.skipped - before.skipped + self.unknown,
            atlas_bytes: self.glyphs.atlas().bytes(),
        };
        self.last = Some(Unpresented { done, built });
        done
    }

    /// Says the draw of the frame last painted was refused: what that
    /// paint answered is answered again by the next, as if the two were
    /// one draw.
    pub fn refused(&mut self) {
        if let Some(last) = self.last.take() {
            self.carried = last;
        }
    }

    /// The quads of the frame last painted, in drawing order.
    pub fn quads(&self) -> &[Quad] {
        &self.quads
    }

    /// The kind of mask the last paint asked its glyph images in; none
    /// before a first paint. It is what that paint did, kept as it did
    /// it, whether or not its draw was then presented.
    pub fn masks(&self) -> Option<Masks> {
        self.masks
    }

    /// The pages the glyph quads read.
    pub fn atlas(&self) -> &Atlas {
        self.glyphs.atlas()
    }

    /// What the glyph cache has done since the painter was made: for
    /// tests.
    #[cfg(test)]
    pub fn glyph_stats(&self) -> crate::glyphs::Stats {
        self.glyphs.stats()
    }

    /// The rasteriser: what makes the glyph images.
    pub fn rasterizer(&self) -> &Z {
        &self.rasterizer
    }

    /// Makes `rasterizer` the one glyph images are made by from here on.
    /// Every image the cache holds is let go, and every row kept with it:
    /// their quads read atlas slots and pin keys of the rasteriser before,
    /// so the next paint builds every row again, as for a frame of another
    /// generation.
    pub fn set_rasterizer(&mut self, rasterizer: Z) {
        self.rasterizer = rasterizer;
        self.glyphs.clear();
        self.rows = RowCache::new();
        self.generation = None;
    }
}

/// The paint of the run of `row` that holds the byte `cluster` of the
/// row's text; the base paint when no run does.
fn paint_at(row: &RowRef<'_>, cluster: usize) -> Paint {
    let offset = cluster.saturating_sub(row.line.bytes.start);
    row.runs
        .iter()
        .find(|(bytes, _)| bytes.contains(&offset))
        .map_or_else(Paint::default, |(_, paint)| *paint)
}

/// How a row's glyph images are asked for.
#[derive(Debug, Clone, Copy)]
struct Asked {
    /// As subpixel masks, and not plain ones.
    subpixel: bool,
    /// In the luminance bucket of each glyph's run, for a rasteriser whose
    /// images depend on it; in bucket 0 otherwise.
    tinted: bool,
}

/// Builds the quads of `row`, relative to its start, taking its glyph
/// images through `image`.
fn build_row(
    row: &RowRef<'_>,
    fonts: &[ResolvedFont],
    line: u32,
    image: &mut dyn FnMut(GlyphKey, &ResolvedFont) -> Option<crate::glyphs::Placed>,
    asked: Asked,
    unknown: &mut u64,
) -> RowQuads {
    let mut built = RowQuads::default();
    let mut spans: Vec<Span> = Vec::new();
    for glyph in &row.line.glyphs {
        let paint = paint_at(row, glyph.cluster);
        let font = usize::try_from(glyph.font.0)
            .ok()
            .and_then(|index| fonts.get(index));
        let end = glyph.x + glyph.advance;
        match spans.last_mut() {
            Some(span) if span.paint == paint => span.end = span.end.max(end),
            _ => spans.push(Span {
                start: glyph.x,
                end,
                paint,
                size: font.map_or(0.0, |font| font.size),
            }),
        }
        let Some(font) = font else {
            *unknown += 1;
            continue;
        };
        let (whole, bin) = bin_of(glyph.x + glyph.dx);
        let key = GlyphKey {
            font: glyph.font,
            glyph: glyph.id,
            bin,
            subpixel: asked.subpixel,
            bucket: if asked.tinted {
                luminance_bucket(paint.foreground)
            } else {
                0
            },
        };
        let Some(placed) = image(key, font) else {
            continue;
        };
        built.pins.push(key);
        let Some(slot) = placed.slot else {
            continue;
        };
        built.glyphs.push(Quad {
            x: whole + placed.left,
            y: pixel(row.baseline + glyph.dy) - placed.top,
            width: slot.width,
            height: slot.height,
            kind: match placed.kind {
                Kind::Mask => QuadKind::Mask,
                Kind::Subpixel => QuadKind::Subpixel,
                Kind::Color => QuadKind::Color,
            },
            color: paint.foreground,
            page: slot.page,
            u: slot.x,
            v: slot.y,
        });
    }
    // A status row's boxes, under its runs' backgrounds: the padding of
    // each field, which has no glyph to carry a run, in its colour.
    for status_box in row.boxes {
        let (left, right) = (pixel(status_box.x), pixel(status_box.x + status_box.width));
        let across = (right - left).max(0) as u32;
        built
            .backgrounds
            .push(Quad::fill(left, 0, across, 0, status_box.background));
    }
    let baseline = pixel(row.baseline);
    for span in &spans {
        let (left, right) = (pixel(span.start), pixel(span.end));
        let across = (right - left).max(0) as u32;
        built
            .backgrounds
            .push(Quad::fill(left, 0, across, 0, span.paint.background));
        if let Some((style, color)) = span.paint.underline {
            underline(&mut built.lines, style, color, left, right, baseline, line);
        }
        if span.paint.strike_through {
            let top = pixel(row.baseline - span.size * 0.3);
            built
                .lines
                .push(Quad::fill(left, top, across, line, span.paint.foreground));
        }
    }
    built
}

/// Adds the quads of an underline of `style` and `color` from `left` to
/// `right`, under the baseline at `baseline`, `line` pixels thick.
fn underline(
    quads: &mut Vec<Quad>,
    style: UnderlineStyle,
    color: Color,
    left: i32,
    right: i32,
    baseline: i32,
    line: u32,
) {
    let step = line as i32;
    let top = baseline + step;
    let across = (right - left).max(0) as u32;
    // For each cell `width` pixels across, counted from the row's start,
    // the part of it between `left` and `right`, drawn as far below `top`
    // as `down` says, or not at all.
    let cells = |quads: &mut Vec<Quad>, width: i32, down: &dyn Fn(i32) -> Option<i32>| {
        for cell in left.div_euclid(width)..=(right - 1).div_euclid(width) {
            let (from, to) = ((cell * width).max(left), ((cell + 1) * width).min(right));
            if let (Some(down), true) = (down(cell), to > from) {
                let part = (to - from) as u32;
                quads.push(Quad::fill(from, top + down, part, line, color));
            }
        }
    };
    match style {
        UnderlineStyle::None => {}
        UnderlineStyle::Single => quads.push(Quad::fill(left, top, across, line, color)),
        UnderlineStyle::Double => {
            quads.push(Quad::fill(left, top, across, line, color));
            quads.push(Quad::fill(left, top + 2 * step, across, line, color));
        }
        UnderlineStyle::Dotted => cells(quads, step, &|cell| (cell % 2 == 0).then_some(0)),
        UnderlineStyle::Dashed => cells(quads, 3 * step, &|cell| (cell % 2 == 0).then_some(0)),
        UnderlineStyle::Curly => cells(quads, 2 * step, &|cell| Some(cell.rem_euclid(2) * step)),
    }
}

/// Adds the quads of `view` to `quads`, in drawing order, clipped to the
/// view's rectangle and to `whole`.
fn place_view(
    view: &ViewFrame,
    rows: &RowCache<RowQuads>,
    whole: Clip,
    line: u32,
    quads: &mut Vec<Quad>,
) {
    let (left, top) = (view.rect.x as i32, view.rect.y as i32);
    let clip = Clip::of(left, top, view.rect.width, view.rect.height).and(whole);
    let mut push = |quad: Quad, clip: Clip| quads.extend(quad.clipped(clip));
    push(
        Quad::fill(
            left,
            top,
            view.rect.width,
            view.rect.height,
            view.background,
        ),
        clip,
    );
    // Each text row's quads, with where its left, its top and its bottom
    // are: its `x` and `y` on whole pixels, as a padded view's may not be.
    let placed: Vec<Placed<'_>> = view
        .rows
        .iter()
        .filter_map(|row| {
            let built = rows.get(row.hash)?;
            Some(Placed {
                quads: built,
                left: left + pixel(row.x),
                from: top + pixel(row.y),
                to: top + pixel(row.y + row.height),
            })
        })
        .collect();
    for row in &placed {
        backgrounds(
            row.quads,
            view.background,
            row.left,
            row.from,
            row.to,
            &mut |quad| {
                push(quad, clip);
            },
        );
    }
    for area in &view.selections {
        let quad = Quad::over(area.x, area.y, area.width, area.height, view.selection);
        push(quad.moved(left, top), clip);
    }
    for row in &placed {
        for quad in &row.quads.glyphs {
            push(quad.moved(row.left, row.from), clip);
        }
    }
    for row in &placed {
        for quad in &row.quads.lines {
            push(quad.moved(row.left, row.from), clip);
        }
    }
    if let Some(status) = &view.status {
        let (from, to) = (top + pixel(status.y), top + pixel(status.y + status.height));
        let down = (to - from).max(0) as u32;
        push(
            Quad::fill(left, from, view.rect.width, down, status.background),
            clip,
        );
        if let Some(row) = rows.get(status.hash) {
            backgrounds(row, status.background, left, from, to, &mut |quad| {
                push(quad, clip);
            });
            for quad in row.glyphs.iter().chain(&row.lines) {
                push(quad.moved(left, from), clip);
            }
        }
    }
    for cursor in &view.cursors {
        place_cursor(cursor, &placed, (left, top), clip, line, &mut push);
    }
}

/// A text row's kept quads, where they are placed: its left and its top,
/// and its bottom, in the target's whole pixels.
struct Placed<'a> {
    /// The row's quads, relative to its start.
    quads: &'a RowQuads,
    /// Its left: the view's, and the row's `x` on a whole pixel.
    left: i32,
    /// Its top.
    from: i32,
    /// Its bottom.
    to: i32,
}

/// Hands `push` the background of each run of `row` that is not `behind`,
/// the colour already there, from `from` down to `to`.
fn backgrounds(
    row: &RowQuads,
    behind: Color,
    left: i32,
    from: i32,
    to: i32,
    push: &mut dyn FnMut(Quad),
) {
    for quad in row.backgrounds.iter().filter(|quad| quad.color != behind) {
        push(Quad {
            height: (to - from).max(0) as u32,
            ..quad.moved(left, from)
        });
    }
}

/// Hands `push` the quads of `cursor`, a cursor of a view whose top left
/// is `origin` and whose text rows are `rows`, placed.
fn place_cursor(
    cursor: &CursorBox,
    rows: &[Placed<'_>],
    origin: (i32, i32),
    clip: Clip,
    line: u32,
    push: &mut dyn FnMut(Quad, Clip),
) {
    let (area, color) = (cursor.area, cursor.paint.background);
    let cell = Quad::over(area.x, area.y, area.width, area.height, color).moved(origin.0, origin.1);
    let (across, down) = (line.min(cell.width), line.min(cell.height));
    let bottom = cell.y + (cell.height - down) as i32;
    match cursor.shape {
        CursorShape::Block => {
            push(cell, clip);
            // The glyphs under it again, in the cursor's foreground, as
            // far as the cursor reaches. A colour glyph keeps its
            // colours.
            let under = Clip::of(cell.x, cell.y, cell.width, cell.height).and(clip);
            for row in rows {
                for quad in &row.quads.glyphs {
                    push(
                        Quad {
                            color: cursor.paint.foreground,
                            ..quad.moved(row.left, row.from)
                        },
                        under,
                    );
                }
            }
        }
        CursorShape::Bar => push(Quad::fill(cell.x, cell.y, across, cell.height, color), clip),
        CursorShape::Underline => push(Quad::fill(cell.x, bottom, cell.width, down, color), clip),
        CursorShape::Hollow => {
            let right = cell.x + (cell.width - across) as i32;
            push(Quad::fill(cell.x, cell.y, cell.width, down, color), clip);
            push(Quad::fill(cell.x, bottom, cell.width, down, color), clip);
            push(Quad::fill(cell.x, cell.y, across, cell.height, color), clip);
            push(Quad::fill(right, cell.y, across, cell.height, color), clip);
        }
    }
}

#[cfg(test)]
mod tests;
