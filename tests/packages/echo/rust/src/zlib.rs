//! The system's zlib: the CRC-32 of a reply's text, from zlib's `crc32`.
//!
//! The adapter of a system library, linked by name (`#[link(name = "z")]`)
//! into echo's own library. On Linux the library is `zlib1g-dev`'s
//! (`tools/linux/Dockerfile`); macOS ships it.
//!
//! This binding is echo's one marked `unsafe` site: a system C library of
//! the package's own choosing, no part of the runtime or its C interface,
//! which the package wrapper wraps. Should a reader want none at all, a
//! table-driven CRC-32 in Rust gives the same value (the Lean side's
//! `Echo.Checksum` computes it) and drops zlib.

#![expect(
    unsafe_code,
    reason = "a binding of a system C library of the package's own choosing, no part of the runtime or its C interface: its declaration and its call"
)]

use std::os::raw::{c_uint, c_ulong};

#[link(name = "z")]
unsafe extern "C" {
    /// zlib's running CRC-32: `crc` updated with the `len` bytes at `buf`.
    fn crc32(crc: c_ulong, buf: *const u8, len: c_uint) -> c_ulong;
}

/// The CRC-32 of `bytes`, as zlib computes it.
pub fn checksum(bytes: &[u8]) -> u32 {
    let mut crc: c_ulong = 0;
    for chunk in bytes.chunks(c_uint::MAX as usize) {
        // SAFETY: the pointer and length are the chunk's, and zlib reads
        // only them. Each chunk's length fits a `c_uint`.
        crc = unsafe { crc32(crc, chunk.as_ptr(), chunk.len() as c_uint) };
    }
    // zlib's CRC-32 is 32 bits wide, whatever the width of `c_ulong`.
    crc as u32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_checksum_of_nothing_is_zero() {
        assert_eq!(checksum(b""), 0);
    }

    #[test]
    fn the_checksum_of_the_check_string_is_crc_32s_check_value() {
        assert_eq!(checksum(b"123456789"), 0xCBF4_3926);
    }

    #[test]
    fn the_checksum_of_text_is_that_of_its_utf_8_bytes() {
        assert_eq!(checksum("héllo".as_bytes()), 0x9E3B_8236);
    }
}
