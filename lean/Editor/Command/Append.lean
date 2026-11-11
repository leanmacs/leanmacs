import Editor.Text

/-!
# A command: append to a text

The first command, and the pattern later ones follow. A command is an
ordinary definition at `EditorM`, written in `do` notation over the port's
operations. It is one source: tests run it against the pure model
(`ModelTest.commandProperties`), and the `editor` executable runs the same
value against the real binding.
-/

namespace Editor

/-- Appends `s` to the end of `text`: reads it, then inserts at its length in
bytes, which is the offset just past its last character. -/
def append (text : TextId) (s : String) : EditorM Unit := do
  let old ← text.read
  text.insert old.utf8ByteSize s

end Editor
