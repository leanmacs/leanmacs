//! A picture as the bytes of a PNG file, and how two pictures differ.
//!
//! The one place the `png` crate is named: [`decode`] and [`encode`] are
//! [`Image::from_png`] and [`Image::to_png`], and no type of the library
//! is public. A picture read is 8 bits a channel, RGB or RGBA; a picture
//! written is RGB, 8 bits a channel, at high compression, since what this
//! crate draws is opaque everywhere. They are what the reference images
//! are read and written with: this crate's own (`tests/reference.rs`,
//! `examples/reference.rs`) and the shipped themes' pictures, which
//! `editor-ffi` hands to Lean's `ffi-test`.

use std::io::Cursor;

use crate::Image;

// The library, named from the root: this module has its name.
use ::png as library;

/// The picture the PNG file `bytes` holds: 8 bits a channel, with or
/// without an alpha. Refused, with a sentence, when the bytes are not a
/// PNG file or hold another kind of picture.
pub(crate) fn decode(bytes: &[u8]) -> Result<Image, String> {
    let mut reader = library::Decoder::new(Cursor::new(bytes))
        .read_info()
        .map_err(|error| format!("not a PNG file: {error}"))?;
    let size = reader
        .output_buffer_size()
        .ok_or_else(|| String::from("a PNG file too large to read"))?;
    let mut buffer = vec![0; size];
    let info = reader
        .next_frame(&mut buffer)
        .map_err(|error| format!("a PNG file whose data cannot be read: {error}"))?;
    if info.bit_depth != library::BitDepth::Eight {
        return Err(format!(
            "a PNG file of {:?} bits a channel, not 8",
            info.bit_depth
        ));
    }
    let data = &buffer[..info.buffer_size()];
    let rgba = match info.color_type {
        library::ColorType::Rgba => data.to_vec(),
        library::ColorType::Rgb => data
            .as_chunks::<3>()
            .0
            .iter()
            .flat_map(|pixel| [pixel[0], pixel[1], pixel[2], 0xff])
            .collect(),
        other => return Err(format!("a PNG file in {other:?}, neither RGB nor RGBA")),
    };
    Ok(Image {
        width: info.width,
        height: info.height,
        rgba,
    })
}

/// `image` as the bytes of a PNG file: RGB, 8 bits a channel, without its
/// alpha.
pub(crate) fn encode(image: &Image) -> Vec<u8> {
    let mut bytes = Vec::new();
    let mut encoder = library::Encoder::new(&mut bytes, image.width, image.height);
    encoder.set_color(library::ColorType::Rgb);
    encoder.set_depth(library::BitDepth::Eight);
    encoder.set_compression(library::Compression::High);
    let rgb: Vec<u8> = image
        .rgba
        .as_chunks::<4>()
        .0
        .iter()
        .flat_map(|pixel| [pixel[0], pixel[1], pixel[2]])
        .collect();
    // Writing to memory fails only on a picture whose data is not its
    // size, which an `Image` of this crate never is.
    let written = encoder.write_header().and_then(|mut writer| {
        writer.write_image_data(&rgb)?;
        writer.finish()
    });
    if written.is_err() {
        bytes.clear();
    }
    bytes
}

/// How `image` differs from `other`: `None` when they are not the same
/// size, and otherwise the largest difference of any channel of any pixel,
/// with how many pixels differ at all.
pub(crate) fn difference(image: &Image, other: &Image) -> Option<(u8, usize)> {
    if (image.width, image.height) != (other.width, other.height) {
        return None;
    }
    let pixels = image.rgba.as_chunks::<4>().0;
    let others = other.rgba.as_chunks::<4>().0;
    let mut worst = 0;
    let mut differing = 0;
    for (pixel, other) in pixels.iter().zip(others) {
        let most = pixel
            .iter()
            .zip(other)
            .map(|(one, two)| one.abs_diff(*two))
            .max()
            .unwrap_or(0);
        worst = worst.max(most);
        differing += usize::from(most > 0);
    }
    Some((worst, differing))
}

#[cfg(test)]
mod tests {
    use super::super::Image;

    /// A picture 3 pixels across and 2 down, each pixel another colour,
    /// opaque.
    fn three_by_two() -> Image {
        let rgba = (0..6u8)
            .flat_map(|index| [index * 40, 255 - index * 40, index * 7, 0xff])
            .collect();
        Image {
            width: 3,
            height: 2,
            rgba,
        }
    }

    #[test]
    fn a_picture_comes_back_from_its_png_file() {
        let image = three_by_two();
        let bytes = image.to_png();
        assert_eq!(&bytes[..8], b"\x89PNG\r\n\x1a\n");
        assert_eq!(Image::from_png(&bytes), Ok(image));
    }

    #[test]
    fn an_rgb_file_is_read_opaque() {
        // `to_png` writes RGB, with no alpha: what comes back is opaque
        // whatever the alpha written was.
        let mut image = three_by_two();
        image.rgba[3] = 0x10;
        let read = Image::from_png(&image.to_png()).expect("a PNG file");
        assert_eq!(read.pixel(0, 0).map(|pixel| pixel[3]), Some(0xff));
        assert_eq!(read.rgba[..3], image.rgba[..3]);
    }

    #[test]
    fn bytes_that_are_not_a_png_file_are_refused() {
        assert!(Image::from_png(b"not a picture").is_err());
        assert!(Image::from_png(&[]).is_err());
    }

    #[test]
    fn two_pictures_differ_by_their_worst_channel_in_so_many_pixels() {
        let image = three_by_two();
        assert_eq!(image.difference(&image), Some((0, 0)));
        let mut other = image.clone();
        other.rgba[0] = other.rgba[0].wrapping_add(3);
        other.rgba[5] = other.rgba[5].wrapping_sub(9);
        other.rgba[22] = other.rgba[22].wrapping_add(1);
        assert_eq!(image.difference(&other), Some((9, 3)));
        assert_eq!(other.difference(&image), Some((9, 3)));
        // Pictures of other sizes do not compare.
        let narrower = Image {
            width: 2,
            height: 3,
            rgba: image.rgba.clone(),
        };
        assert_eq!(image.difference(&narrower), None);
    }
}
