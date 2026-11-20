-- Quoted whole in docs/packages/writing-a-package.md, "Developing it live,
-- as config": change the guide with it.
import Editor
open Editor

namespace Config.WordCount

/-- The number of words in `text`: its runs of characters that are not
white space. -/
def count (text : String) : Nat :=
  ((text.split Char.isWhitespace).toList.filter fun word => !word.isEmpty).length

/-- Says how many words the focused window's buffer holds. -/
def countFocused : EditorM Unit := do
  let some target := (← editorState).focusedTarget?
    | message "word-count: no window is focused"
  let text ← target.buffer.text.read
  message s!"{count text} words"

/-- Registers the command `word-count`. -/
def setup : SetupM Unit :=
  command "word-count" countFocused

end Config.WordCount
