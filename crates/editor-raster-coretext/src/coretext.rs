//! The macOS adapters: [`CoreTextRasterizer`], which has Core Text draw
//! each glyph, and [`SystemDefaults`], which reads `AppleFontSmoothing`.
//!
//! Every decision is in the pure modules, tested in the gate: what is
//! declined ([`decline`](crate::decline)), the bitmap and the pen
//! ([`bounds`](crate::bounds)), the grey ([`fill`](crate::fill)) and
//! whether text is smoothed ([`defaults`](crate::defaults)). This module
//! carries them out, and no test calls it: what Core Text draws is the
//! system's (the crate's docs, "What runs where").
//!
//! # How a glyph is drawn
//!
//! The face is loaded from the frame's bytes, with no copy and nothing
//! registered on the system (`CTFontManagerCreateFontDescriptorsFromData`,
//! which honours the face index of a collection), and made at the font's
//! size in pixels. The glyph is drawn into an 8-bit alpha-only bitmap of
//! one byte a pixel, not scaled: 14 points at scale 2 is the same drawing
//! as 28 pixels at scale 1. Antialiasing is on; smoothing is allowed and
//! on as the user's preference says; subpixel positioning is on and
//! subpixel quantisation off, so the pen goes where it is put, a whole
//! pixel and the bin's fraction right of the bitmap's left; and the fill
//! is the grey of the run's luminance bucket. What comes back is the
//! bitmap's alpha, a plain mask: macOS draws no subpixel text, so a
//! subpixel mask asked for is a plain one too. Core Text does not hint.

use std::collections::HashMap;
use std::collections::hash_map::Entry;
use std::ffi::c_void;
use std::ptr::NonNull;
use std::sync::Arc;

use editor_raster::{GlyphImage, GlyphRequest, Kind, Rasterize, ResolvedFont};
use objc2_core_foundation::{
    CFArray, CFData, CFIndex, CFNumber, CFRetained, CFString, CGPoint, CGRect, kCFAllocatorNull,
};
use objc2_core_graphics::{CGBitmapContextCreate, CGColorSpace, CGContext, CGImageAlphaInfo};
use objc2_core_text::{
    CTFont, CTFontDescriptor, CTFontManagerCreateFontDescriptorsFromData, CTFontOrientation,
    CTFontTableOptions,
};

use crate::bounds::Frame;
use crate::decline::{FontFacts, declines};
use crate::defaults::{FontDefaults, Preference, smoothing};
use crate::fill::fill_grey;

/// What a face is kept by: its file's bytes, by where they are, and its
/// index in the file.
type FaceKey = (usize, u32);

/// A face loaded from a frame's bytes.
struct Face {
    /// The bytes, kept so that they outlive the `CFData` over them, which
    /// does not copy them.
    _bytes: Arc<dyn AsRef<[u8]> + Send + Sync>,
    /// The face's descriptor, made from the bytes.
    descriptor: CFRetained<CTFontDescriptor>,
    /// The four-byte tags of its tables, for what is declined.
    tables: Option<Vec<[u8; 4]>>,
}

/// The faces and fonts made so far.
#[derive(Default)]
struct Fonts {
    /// The faces, by their bytes and index.
    faces: HashMap<FaceKey, Face>,
    /// The fonts, by their face and their size's bits.
    fonts: HashMap<(FaceKey, u32), CFRetained<CTFont>>,
}

// SAFETY: Core Text's fonts and font descriptors are immutable once made,
// and Apple documents them as safe to use from any thread; the bytes they
// read are an `Arc` that is `Send` and `Sync`. `CFRetained` is `Send` only
// for a type that is `Sync`, which objc2 does not claim for these
// toll-free bridged types, so the claim is made here. The rasteriser that
// holds them is used by one thread at a time (`&mut self`), and is never
// shared.
unsafe impl Send for Fonts {}

/// The key of the face of `font`.
fn face_key(font: &ResolvedFont) -> FaceKey {
    (Arc::as_ptr(&font.data).cast::<()>() as usize, font.index)
}

/// The bytes of the file of `font`.
fn bytes(font: &ResolvedFont) -> &[u8] {
    (*font.data).as_ref()
}

impl Fonts {
    /// The face of `font`, loaded on first use; `None` for bytes that hold
    /// no face of its index.
    fn face(&mut self, font: &ResolvedFont) -> Option<&Face> {
        match self.faces.entry(face_key(font)) {
            Entry::Occupied(held) => Some(held.into_mut()),
            Entry::Vacant(empty) => Some(empty.insert(load(font)?)),
        }
    }

    /// `font` as Core Text's, at its size; with its face.
    fn font(&mut self, font: &ResolvedFont) -> Option<(&Face, &CTFont)> {
        let key = (face_key(font), font.size.to_bits());
        if !self.fonts.contains_key(&key) {
            let descriptor = CFRetained::clone(&self.face(font)?.descriptor);
            // SAFETY: the descriptor is a live one, and no matrix is given.
            let made = unsafe {
                CTFont::with_font_descriptor(&descriptor, f64::from(font.size), std::ptr::null())
            };
            self.fonts.insert(key, made);
        }
        let face = self.faces.get(&key.0)?;
        Some((face, self.fonts.get(&key)?))
    }
}

/// The face of `font`'s bytes and index, with its tables.
fn load(font: &ResolvedFont) -> Option<Face> {
    let file = bytes(font);
    if file.is_empty() {
        return None;
    }
    let length = CFIndex::try_from(file.len()).ok()?;
    // SAFETY: the bytes are valid for `length`, and outlive the data: the
    // face keeps the `Arc` that holds them. The null deallocator frees
    // nothing.
    let data =
        unsafe { CFData::with_bytes_no_copy(None, file.as_ptr(), length, kCFAllocatorNull) }?;
    // SAFETY: `data` is a live `CFData`.
    let descriptors: CFRetained<CFArray> =
        unsafe { CTFontManagerCreateFontDescriptorsFromData(&data) };
    let index = CFIndex::try_from(font.index).ok()?;
    if index >= descriptors.count() {
        return None;
    }
    // SAFETY: the index is in the array, whose values are font
    // descriptors; retaining one keeps it past the array.
    let descriptor = unsafe {
        let value = descriptors.value_at_index(index);
        CFRetained::retain(NonNull::new(value.cast_mut().cast::<CTFontDescriptor>())?)
    };
    // SAFETY: as above, and no matrix is given.
    let probe = unsafe { CTFont::with_font_descriptor(&descriptor, 12.0, std::ptr::null()) };
    Some(Face {
        _bytes: Arc::clone(&font.data),
        tables: tables(&probe),
        descriptor,
    })
}

/// The tags of `font`'s tables: `None` when Core Text gives none.
fn tables(font: &CTFont) -> Option<Vec<[u8; 4]>> {
    // SAFETY: the font is live.
    let tags = unsafe { font.available_tables(CTFontTableOptions::NoOptions) }?;
    // The array holds each tag as its value, not as an object.
    Some(
        (0..tags.count())
            // SAFETY: the index is in the array.
            .map(|index| unsafe { tags.value_at_index(index) } as usize as u32)
            .map(u32::to_be_bytes)
            .collect(),
    )
}

/// The ids of the glyphs `font` draws the characters of `text` with, one
/// for each, read from the font's own character map through Core Text;
/// `None` when the font has no face, a character is not in the Basic
/// Multilingual Plane, or the font has no glyph for one.
pub fn glyphs_of(font: &ResolvedFont, text: &str) -> Option<Vec<u32>> {
    let mut fonts = Fonts::default();
    let (_, made) = fonts.font(font)?;
    let mut characters: Vec<u16> = Vec::new();
    for character in text.chars() {
        let mut units = [0_u16; 2];
        if character.encode_utf16(&mut units).len() != 1 {
            return None;
        }
        characters.push(units[0]);
    }
    let mut glyphs = vec![0_u16; characters.len()];
    let count = CFIndex::try_from(characters.len()).ok()?;
    // SAFETY: both buffers hold `count` values.
    let all = unsafe {
        made.glyphs_for_characters(
            NonNull::new(characters.as_mut_ptr())?,
            NonNull::new(glyphs.as_mut_ptr())?,
            count,
        )
    };
    all.then(|| glyphs.into_iter().map(u32::from).collect())
}

/// The rasteriser over Core Text.
pub struct CoreTextRasterizer {
    /// The faces and fonts made so far.
    fonts: Fonts,
    /// Whether text is smoothed: the user's preference, decided.
    smoothing: bool,
}

impl CoreTextRasterizer {
    /// A rasteriser that has made nothing, which smooths text or not as
    /// `smoothing` says.
    pub fn new(smoothing: bool) -> Self {
        Self {
            fonts: Fonts::default(),
            smoothing,
        }
    }

    /// A rasteriser that smooths text as `defaults` say, read once now.
    pub fn from_defaults(defaults: &impl FontDefaults) -> Self {
        Self::new(smoothing(defaults.font_smoothing()))
    }

    /// Whether it smooths text.
    pub fn smooths(&self) -> bool {
        self.smoothing
    }

    /// The mask of `glyph` of `font` drawn `offset` pixels right of a
    /// whole pixel, in the grey of `bucket`: the adapter's own drawing,
    /// which [`Rasterize::rasterize`] calls with the bin's offset, and the
    /// way in of the example `check`, which draws at Core Text's own
    /// offsets too. `None` for a font with no face, a glyph it does not
    /// have, or a font the adapter declines.
    pub fn draw_at(
        &mut self,
        font: &ResolvedFont,
        glyph: u32,
        offset: f64,
        bucket: u8,
    ) -> Option<GlyphImage> {
        let glyph = u16::try_from(glyph).ok()?;
        let smoothing = self.smoothing;
        let (face, made) = self.fonts.font(font)?;
        let facts = FontFacts::of(font, face.tables.as_deref().unwrap_or(&[]));
        if declines(&facts) {
            return None;
        }
        // SAFETY: the font is live.
        if CFIndex::try_from(glyph).ok()? >= unsafe { made.glyph_count() } {
            return None;
        }
        let mut glyphs = [glyph];
        let mut rect = CGRect::default();
        // SAFETY: one glyph, and room for one rectangle.
        unsafe {
            made.bounding_rects_for_glyphs(
                CTFontOrientation::Horizontal,
                NonNull::from(&mut glyphs[0]),
                &mut rect,
                1,
            );
        }
        let frame = Frame::of(
            [
                rect.origin.x,
                rect.origin.y,
                rect.origin.x + rect.size.width,
                rect.origin.y + rect.size.height,
            ],
            offset,
        );
        let data = if frame.width == 0 || frame.height == 0 {
            Vec::new()
        } else {
            draw(made, glyph, &frame, smoothing, fill_grey(bucket))?
        };
        Some(GlyphImage {
            kind: Kind::Mask,
            width: frame.width,
            height: frame.height,
            left: frame.left,
            top: frame.top,
            data,
        })
    }
}

/// `glyph` of `font` drawn in a bitmap of `frame`'s size at its origin,
/// smoothed or not, in the grey `fill`: the bitmap's alpha, row by row
/// from the top.
fn draw(font: &CTFont, glyph: u16, frame: &Frame, smoothing: bool, fill: f64) -> Option<Vec<u8>> {
    let (width, height) = (frame.width as usize, frame.height as usize);
    let mut pixels = vec![0_u8; width * height];
    let space: CFRetained<CGColorSpace> = CGColorSpace::new_device_gray()?;
    // SAFETY: the buffer holds `height` rows of `width` bytes, one byte
    // a pixel of alpha, and outlives the context, which is dropped below
    // before the buffer is read.
    let context: CFRetained<CGContext> = unsafe {
        CGBitmapContextCreate(
            pixels.as_mut_ptr().cast::<c_void>(),
            width,
            height,
            8,
            width,
            Some(&space),
            CGImageAlphaInfo::Only.0,
        )
    }?;
    let context_ref = Some(&*context);
    CGContext::set_allows_antialiasing(context_ref, true);
    CGContext::set_should_antialias(context_ref, true);
    CGContext::set_allows_font_smoothing(context_ref, true);
    CGContext::set_should_smooth_fonts(context_ref, smoothing);
    CGContext::set_allows_font_subpixel_positioning(context_ref, true);
    CGContext::set_should_subpixel_position_fonts(context_ref, true);
    CGContext::set_allows_font_subpixel_quantization(context_ref, true);
    CGContext::set_should_subpixel_quantize_fonts(context_ref, false);
    CGContext::set_gray_fill_color(context_ref, fill, 1.0);
    let mut glyphs = [glyph];
    let mut positions = [CGPoint {
        x: frame.origin.0,
        y: frame.origin.1,
    }];
    // SAFETY: one glyph and one position, and a live context.
    unsafe {
        font.draw_glyphs(
            NonNull::from(&mut glyphs[0]),
            NonNull::from(&mut positions[0]),
            1,
            &context,
        );
    }
    CGContext::flush(context_ref);
    drop(context);
    Some(pixels)
}

impl Rasterize for CoreTextRasterizer {
    fn rasterize(&mut self, request: &GlyphRequest<'_>) -> Option<GlyphImage> {
        let key = request.key;
        self.draw_at(request.font, key.glyph, f64::from(key.offset()), key.bucket)
    }

    /// Smoothed text is dilated by the fill's luminance; text that is not
    /// is the same whatever the fill.
    fn by_luminance(&self) -> bool {
        self.smoothing
    }

    /// Seen in the window's check (`mise run window-contract`), which
    /// prints what each renderer draws with.
    fn name(&self) -> &'static str {
        "Core Text"
    }
}

/// The system's font defaults: the user's preferences, read through
/// CoreFoundation.
#[derive(Debug, Clone, Copy)]
pub struct SystemDefaults(());

impl SystemDefaults {
    /// The defaults of the user who runs this process. What they hold
    /// depends on the machine and the user, so no test calls it: the
    /// root `clippy.toml` forbids it to them.
    #[expect(
        clippy::new_without_default,
        reason = "a `Default` would read this machine's defaults by a name the root `clippy.toml` does not forbid"
    )]
    pub fn new() -> Self {
        Self(())
    }
}

impl FontDefaults for SystemDefaults {
    fn font_smoothing(&self) -> Preference {
        let key = CFString::from_static_str("AppleFontSmoothing");
        // SAFETY: a constant of CoreFoundation's, always set.
        let application = unsafe { objc2_core_foundation::kCFPreferencesCurrentApplication };
        let Some(value) = objc2_core_foundation::CFPreferencesCopyAppValue(&key, application)
        else {
            return Preference::Missing;
        };
        match value.downcast::<CFNumber>() {
            Ok(number) => number
                .as_i64()
                .map_or(Preference::Other, Preference::Integer),
            Err(_) => Preference::Other,
        }
    }
}
