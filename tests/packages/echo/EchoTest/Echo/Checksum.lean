import Echo.Checksum

/-!
# Model tests: `Echo/Checksum.lean`

The pure CRC-32 against known vectors: zlib's `crc32` of the same bytes.
The test driver's root, `EchoTest/Model.lean`, runs them.
-/

namespace EchoTest

/-- The checks of the pure checksum, each with what must hold as a
sentence. -/
def echoChecksumChecks : List (String × Bool) :=
  [("the checksum of the empty text is 0", Echo.checksum "" == 0),
    ("the checksum of \"123456789\" is 0xCBF43926, CRC-32's check value",
      Echo.checksum "123456789" == 0xCBF43926),
    ("the checksum of \"héllo\" is that of its UTF-8 bytes, 0x9E3B8236",
      Echo.checksum "héllo" == 0x9E3B8236)]

end EchoTest
