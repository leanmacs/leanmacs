import Editor.Api
import Editor.Invocation
import Editor.State.Request
import Editor.SyntaxTree.Model
import Editor.Test.Loop

/-!
# The test kit: Modes

What a check that enters a mode and reads its highlights runs: the command
`enter` of the on-enter checks, the invocation that runs it
(`entersMode`), what it says of a refusal (`modeRefusalText`), and the
faces the syntax tree model's highlighter last drew (`highlightedFaces`,
`faceNames`). Moved from the core's model test support
(`ModelTest/Support/Modes.lean`, which imports this module and keeps the
mode registries of the core's checks) in the features-as-packages roadmap's
phase 6, so that a package's tests, which may not import the core's test
support, enter a mode on a file they open: the files feature's language
checks do.

Published for a package's tests: a module of the core's test kit, a test
double in the namespace `Editor.Test`.
-/

namespace Editor.Test

open Editor

/-- What the command `enter` of the on-enter checks says of a refusal, in the
echo area. -/
def modeRefusalText : ModeRefusal → String
  | .noSuchWindow id => s!"no window {id.index}"
  | .noSuchMode name => s!"no mode {name}"
  | .noSuchBuffer id => s!"no buffer {id.index}"

/-- The command `enter` of the on-enter checks: it asks for the mode named
by its second argument to be the major mode of the buffer the view of its
first argument shows, by the request (`ViewId.setMajorMode`), and says a
refusal in the echo area. With `fail` it is then refused with
`badRange`. -/
def enter (fail : Bool := false) : Dispatched := fun call => do
  let [.nat view, .str name] := call.arguments | throw .badPosition
  if let .error refusal← (⟨view⟩ : ViewId).setMajorMode name then
    EditorState.ask (.message (modeRefusalText refusal))
  if fail then
    call.target.buffer.text.delete 9 99
  return none

/-- The invocation of `command` that sets the mode `name` through `view`. -/
def entersMode (view : ViewId) (name : String) (command : String := "enter") : Invocation :=
  { command, arguments := [.nat view.index, .str name] }

/-- Each face, by name, `-` for none. -/
def faceNames (faces : Array (Option FaceName)) : Array String :=
  faces.map fun face => (face.map (·.name)).getD "-"

/-- The faces of the syntax tree model's highlighter, by name, `-` for
none; none when no text is highlighted. -/
def highlightedFaces (model : SyntaxTreeModel) : Option (Array String) :=
  model.highlighted.back?.map fun (_, _, faces) => faceNames faces

/-- The indents source of the model's test mode: an object and an array
indent what they hold, and their closing brackets lead out. -/
def jsonIndents : String :=
  "(object) @indent.begin\n(array) @indent.begin\n\"}\" @indent.branch\n\"]\" @indent.branch"

end Editor.Test
