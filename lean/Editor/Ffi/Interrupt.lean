import Editor.Ffi.Words

/-!
# Bindings: the interrupt flag

The bindings of `crates/editor-ffi/src/interrupt.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("The interrupt flag").
-/

namespace Editor.Ffi

open Words

/-- `interruptKeySet` as it crosses: the words as bytes. -/
@[extern "editor_glue_interrupt_key_set"]
private opaque interruptKeySetRaw (words : @& ByteArray) : IO Bool

/-- Makes the key `words` stand for the library's interrupt key ("The
interrupt flag", in the module docs): `[logical tag, n, n scalars,
modifiers, mask]`. From then on a press of that key, with exactly those of
the masked modifiers held, raises the flag as it arrives.

`false`, changing nothing, for words that do not read as a key. The flag is
left as it is either way. -/
def interruptKeySet (words : Array UInt64) : IO Bool :=
  interruptKeySetRaw (words.foldl pushWord ByteArray.empty)

/-- Leaves the library with no interrupt key: nothing raises the flag until
one is set again. The flag is left as it is. -/
@[extern "editor_glue_interrupt_key_clear"]
opaque interruptKeyClear : IO Unit

/-- Whether the library's interrupt flag is up: a press of the interrupt key
has arrived on the editor queue and has not been lowered for. Asking does
not lower it. -/
@[extern "editor_glue_interrupt_raised"]
opaque interruptRaised : IO Bool

/-- Tells the library that one press of the interrupt key was taken off the
queue: one fewer holds the flag up. With none counted, nothing. -/
@[extern "editor_glue_interrupt_lower"]
opaque interruptLower : IO Unit

end Editor.Ffi
