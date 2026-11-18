/-!
# Bindings: the clipboard

The bindings of `crates/editor-ffi/src/clipboard.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("Handles").
-/

namespace Editor.Ffi

/-- The type behind `Clipboard`. It is opaque, so the only ways to get a
clipboard are `Clipboard.memory`, `Clipboard.failing` and
`Clipboard.system`. -/
opaque ClipboardPointed : NonemptyType

/-- A clipboard held by the Rust library (`crates/editor-ffi/src/clipboard.rs`,
over the clipboard port of `crates/editor-platform`): the library's memory
clipboard, its failing one, or the desktop's. The clipboard interface's real
binding runs against it (`Editor/Clipboard/Real.lean`). -/
def Clipboard : Type :=
  ClipboardPointed.type

instance : Nonempty Clipboard :=
  ClipboardPointed.property

/-- A new clipboard in the library's memory that holds nothing: the port's
fake, which no other program sees. Every test is on it. -/
@[extern "editor_glue_clipboard_memory"]
opaque Clipboard.memory : IO Clipboard

/-- A new clipboard of the library's that cannot be reached: every read and
write fails with `reason`, and changes nothing. It is the port's failing
fake, for tests of the failure path (`ContractTest.clipboardChecks`); the
editor never makes one. -/
@[extern "editor_glue_clipboard_failing"]
opaque Clipboard.failing (reason : @& String) : IO Clipboard

/-- The desktop's clipboard, or the reason it cannot be reached. Only the
window mode opens it: what it holds is the person's. -/
@[extern "editor_glue_clipboard_system"]
opaque Clipboard.system : IO (Except String Clipboard)

/-- What a read of the clipboard answers, as the glue builds it: the text or
the reason, then how the read ended (0 text, 1 no text, 2 failed). Object
fields first, so the order here is the layout the glue writes. -/
private structure RawClipboardRead where
  /-- The text held, or the reason the read failed; empty when there is
  no text. -/
  text : String
  /-- How the read ended. -/
  status : UInt64

/-- `Clipboard.read` as it crosses. -/
@[extern "editor_glue_clipboard_read"]
private opaque Clipboard.readRaw (clipboard : @& Clipboard) : IO RawClipboardRead

/-- The text the clipboard holds, `none` when it holds no text, or the
reason it could not be read. -/
def Clipboard.read (clipboard : Clipboard) : IO (Except String (Option String)) := do
  let raw ← clipboard.readRaw
  return match raw.status with
    | 0 => .ok (some raw.text)
    | 1 => .ok none
    | _ => .error raw.text

/-- Has the clipboard hold `text`, in place of what it held: `none` when it
was written, and the reason otherwise. -/
@[extern "editor_glue_clipboard_write"]
opaque Clipboard.write (clipboard : @& Clipboard) (text : @& String) : IO (Option String)

/-- How many clipboards the Rust library holds that have not been freed. -/
@[extern "editor_glue_clipboard_live"]
opaque Clipboard.live : IO UInt64

end Editor.Ffi
