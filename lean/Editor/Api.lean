/-!
# Editor API

The surface user config programs against. The `host*` primitives are
implemented in Rust (bridged through `shim/shim.c`); everything else is
ordinary Lean built on top of them.
-/

namespace Editor

/-- Host primitive: append `s` to the current buffer. -/
@[extern "editor_host_insert"]
opaque hostInsert (s : @& String) : IO Unit

/-- Host primitive: the full text of the current buffer. -/
@[extern "editor_host_buffer_text"]
opaque hostBufferText : IO String

/-- Host primitive: show `s` in the echo area. -/
@[extern "editor_host_message"]
opaque hostMessage (s : @& String) : IO Unit

/-- The editor monad. Plain `IO` for the prototype; later a richer stack
(editor state, capabilities) without changing user-facing signatures. -/
abbrev EditorM :=
  IO

/-- Insert text at the end of the current buffer. -/
def insertText (s : String) : EditorM Unit :=
  hostInsert s

/-- The full text of the current buffer. -/
def bufferText : EditorM String :=
  hostBufferText

/-- Show a message in the echo area (stdout for now). -/
def message (s : String) : EditorM Unit :=
  hostMessage s

end Editor
