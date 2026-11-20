-- Quoted whole in docs/packages/writing-a-package.md: change the guide with it.
import Editor.Api
import Editor.Package

/-!
# The package `word-count`

The example of the guide to writing a package: the command `word-count`
says in the echo area how many words the focused window's buffer holds.
-/

namespace WordCount

open Editor

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

/-- The package `word-count`: the command `word-count`. -/
def package : Package :=
  { name := "word-count"
    setup := command "word-count" countFocused }

end WordCount
