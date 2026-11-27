/-!
# CRC-32 of a text, in Lean alone

The checksum the echo service answers with each reply, computed here with
no library: CRC-32 as zlib computes it (the reflected polynomial
`0xEDB88320`, an initial value and a final mask of all ones), over the
text's UTF-8 bytes. The pure model answers it, so the contract holds the
service's checksum, which the crate computes in Rust (`crc32fast`), to
this one.
-/

namespace Echo

/-- One step of the reflected CRC-32 over one bit, for the polynomial
`0xEDB88320`. -/
def crcStep (crc : UInt32) : UInt32 :=
  if crc &&& (1 : UInt32) == (1 : UInt32) then (0xEDB88320 : UInt32) ^^^ (crc >>> 1) else crc >>> 1

/-- The CRC-32 of each byte value, for the polynomial `0xEDB88320`. -/
def crcTable : Array UInt32 :=
  (Array.range 256).map fun n => (List.range 8).foldl (fun crc _ => crcStep crc) n.toUInt32

/-- The CRC-32 of the UTF-8 bytes of `text`, as zlib's `crc32` gives it. -/
def checksum (text : String) : UInt32 :=
  let crc :=
    text.toUTF8.foldl
      (fun crc byte => crcTable[((crc ^^^ byte.toUInt32) &&& 0xFF).toNat]! ^^^ (crc >>> 8))
      0xFFFFFFFF
  crc ^^^ 0xFFFFFFFF

end Echo
