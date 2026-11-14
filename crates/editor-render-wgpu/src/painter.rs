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
//! For each view, clipped to its rectangle and to the target:
//!
//! 1. its background;
//! 2. the background of each run of each text row, where it is not the
//!    view's;
//! 3. its selection areas;
//! 4. the glyphs of each text row;
//! 5. the underlines and the strike-throughs of each text row;
//! 6. its status row, the same way, over the status row's own background
//!    across the view;
//! 7. its cursors.
//!
//! Nothing is drawn outside a view: the device clears the target first.
//!
//! # Where a glyph goes
//!
//! A glyph's image is placed by the frame's own numbers and no others. Its
//! place across is its `x` plus its `dx`, from its view's left edge,
//! rounded to a quarter of a pixel: the whole pixels place the quad and
//! the quarters pick the image ([`bin_of`]). Its place down is its row's
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
//! A row's quads are built relative to the row's own start (its view's
//! left edge and its own top), so they are the same wherever the row is,
//! and kept by the row's content hash. A row seen again costs nothing but
//! adding its position to its quads: the rasteriser is not asked.
//! Cursors and selections are not part of any row and are made anew each
//! time.
//!
//! Each row pins the glyph images it draws, and lets them go when it is
//! dropped ([`glyphs`](crate::glyphs), "In use is never evicted").
//!
//! # What the scale changes
//!
//! A frame is in physical pixels, so nothing is multiplied by the scale.
//! What the painter itself sizes is as many pixels thick as the scale,
//! rounded, and never less than one: an underline, a strike-through, a
//! bar cursor, an underline cursor and the edge of a hollow cursor. Rows
//! built at one scale are built again at another.
//!
//! # What is not tuned
//!
//! Where an underline and a strike-through sit (the frame carries no
//! metric for either): an underline is one thickness below the baseline,
//! a strike-through three tenths of the font's size above it. A curly
//! underline is a stepped line.

use editor_layout::face::{Color, Paint, UnderlineStyle};
use editor_layout::frame::{CursorBox, Frame, ViewFrame};
use editor_layout::scene::CursorShape;
use editor_layout::shaper::ResolvedFont;
use editor_render::port::{Drawn, Target};
use editor_render::rows::{RowCache, RowRef};

use crate::atlas::Atlas;
use crate::blend::stripes;
use crate::glyphs::{GlyphCache, GlyphImage, GlyphKey, GlyphRequest, Kind, Rasterize, bin_of};
use crate::quads::{Clip, Quad, QuadKind, pixel};
use crate::{Antialiasing, Settings, SubpixelOrder};

/// How many pixels thick a line the painter sizes is at `scale`: the
/// scale rounded, and never less than one.
pub fn thickness(scale: f32) -> u32 {
    (scale.round() as u32).max(1)
}

/// What the painter keeps for a row: its quads, relative to the row's
/// start, and the glyph images it pins.
#[derive(Debug, Default)]
pub struct RowQuads {
    /// The background of each run, in order across the row: its left
    /// edge, its width and its colour. Its height is the row's, which is
    /// set when the row is placed.
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
    /// The glyphs of the frame last painted that name no font of it.
    unknown: u64,
    /// The quads of the frame last painted, in drawing order.
    quads: Vec<Quad>,
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
            unknown: 0,
            quads: Vec::new(),
        }
    }

    /// Paints `frame` for `target`: makes [`Painter::quads`] the list to
    /// draw, and says what that cost. The answer's `presented` is
    /// `false`: presenting is the device's.
    pub fn paint(&mut self, frame: &Frame, target: Target) -> Drawn {
        let before = self.glyphs.stats();
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
        let mut ordered = Ordered {
            inner: rasterizer,
            order,
        };
        let (hint, subpixel) = (self.hint, order.is_some());
        let line = thickness(target.scale);
        let reuse = self.rows.update(frame, target.scale, |row| {
            build_row(
                &row,
                &frame.fonts,
                line,
                &mut |key, font| glyphs.get(key, font, hint, &mut ordered),
                subpixel,
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
        for view in &frame.views {
            place_view(view, &self.rows, whole, line, &mut self.quads);
        }

        let after = self.glyphs.stats();
        Drawn {
            presented: false,
            rows_rebuilt: reuse.rebuilt,
            rows_reused: reuse.reused,
            glyphs_rasterised: after.rasterised - before.rasterised,
            glyphs_reused: after.reused - before.reused,
            glyphs_evicted: after.evicted - before.evicted,
            glyphs_skipped: after.skipped - before.skipped + self.unknown,
            atlas_bytes: self.glyphs.atlas().bytes(),
        }
    }

    /// The quads of the frame last painted, in drawing order.
    pub fn quads(&self) -> &[Quad] {
        &self.quads
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

    /// The rasteriser: for tests, which look at what a fake was asked.
    #[cfg(test)]
    pub fn rasterizer(&self) -> &Z {
        &self.rasterizer
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

/// Builds the quads of `row`, relative to its start, taking its glyph
/// images through `image`.
fn build_row(
    row: &RowRef<'_>,
    fonts: &[ResolvedFont],
    line: u32,
    image: &mut dyn FnMut(GlyphKey, &ResolvedFont) -> Option<crate::glyphs::Placed>,
    subpixel: bool,
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
            subpixel,
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
    // Each text row's quads, with where its top and its bottom are.
    let placed: Vec<(&RowQuads, i32, i32)> = view
        .rows
        .iter()
        .filter_map(|row| {
            let built = rows.get(row.hash)?;
            Some((built, top + pixel(row.y), top + pixel(row.y + row.height)))
        })
        .collect();
    for (row, from, to) in &placed {
        backgrounds(row, view.background, left, *from, *to, &mut |quad| {
            push(quad, clip);
        });
    }
    for area in &view.selections {
        let quad = Quad::over(area.x, area.y, area.width, area.height, view.selection);
        push(quad.moved(left, top), clip);
    }
    for (row, from, _) in &placed {
        for quad in &row.glyphs {
            push(quad.moved(left, *from), clip);
        }
    }
    for (row, from, _) in &placed {
        for quad in &row.lines {
            push(quad.moved(left, *from), clip);
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
/// is `origin` and whose text rows are `rows`.
fn place_cursor(
    cursor: &CursorBox,
    rows: &[(&RowQuads, i32, i32)],
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
            for (row, from, _) in rows {
                for quad in &row.glyphs {
                    push(
                        Quad {
                            color: cursor.paint.foreground,
                            ..quad.moved(origin.0, *from)
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
