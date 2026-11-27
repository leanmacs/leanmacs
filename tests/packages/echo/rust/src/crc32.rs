//! The CRC-32 of a reply's text, from the `crc32fast` library.
//!
//! echo's own seam over the library: the rest of the crate asks
//! [`checksum`], and only this module names `crc32fast`. It is CRC-32 as
//! zlib computes it (the reflected polynomial `0xEDB88320`, starting from
//! and finishing with all ones), the value the Lean side's `Echo.Checksum`
//! computes, which the contract holds the crate's to.
//!
//! It was zlib's `crc32`, linked from the system, until echo was ported
//! onto the package wrapper: that binding was the crate's one `unsafe`
//! site, and a library in Rust gives the same value with none, so the crate
//! keeps `#![deny(unsafe_code)]` whole and links no system library.
//! `crc32fast` is the CRC-32 the workspace already builds (PNG's, through
//! `flate2`), so it adds no version to the lock.

/// The CRC-32 of `bytes`, as zlib computes it.
pub fn checksum(bytes: &[u8]) -> u32 {
    crc32fast::hash(bytes)
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
