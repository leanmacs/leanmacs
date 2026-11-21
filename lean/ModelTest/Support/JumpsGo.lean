import Editor.Buffers
import Editor.Files
import Editor.Files.Kit
import Editor.Jumps.Go
import ModelTest.Support.Jumps

/-!
# Model tests: support: JumpsGo

The jump checks' driver of the files feature: the keys of the core's jump
support (`ModelTest/Support/Jumps.lean`, `jumpBindings`) bound to the real
commands, moving through the list and going to a place (`Jumps.move`,
`Jumps.goTo`, `Editor/Jumps/Go.lean`), opening and visiting a file
(`Files.open`, `Files.visit`), and switching and closing a buffer
(`Buffers.switchTo`, `Buffers.close`), with the files feature's jobs. Shared
by `ModelTest/Editor/Jumps/Go.lean` and `ModelTest/Editor/Evil/Marks.lean`;
it holds no checks of its own.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The commands of the jump checks that are the file and buffer features':
`back`, `forward` and `go-to`, `open`, `visit` and `visit-quietly`,
`switch`, `close` and `close-1`. -/
def jumpGoCommands : List (String × Dispatched) :=
  let view (call : Call) : ViewId := call.target.window.id
  [("back", jumpCommand fun call => discard <| Jumps.move (view call) (-1)),
    ("forward", jumpCommand fun call => discard <| Jumps.move (view call) 1),
    ("go-to", jumpCommand fun call => Jumps.goTo (view call) (.file jumpsPath 1 0) false),
    ("open", jumpCommand fun call => Files.open (view call) jumpsPath),
    ("visit",
      jumpCommand fun call =>
        Files.visit (view call) jumpsPath { row := 1, column := 0, firstNonBlank := true } false),
    ("visit-quietly",
      jumpCommand fun call =>
        Files.visit (view call) jumpsPath { row := 1, column := 0, firstNonBlank := true } false
          (record := false)),
    ("switch", jumpCommand fun call => Buffers.switchTo (view call) EditorState.scratchName),
    ("close", jumpCommand fun call => Buffers.close call.target.window.buffer),
    ("close-1", jumpCommand fun _ => Buffers.close ⟨1⟩)]

/-- The driver of the jump checks of the files feature: the core's commands
and the real ones (`jumpGoCommands`), and the files feature's jobs. -/
def goDriver : Option TestDriver :=
  jumpDriverWith (jumpCoreCommands ++ jumpGoCommands) fileJobs

/-- `driver`, the files feature's, fed the keys `keys`, each followed by
every load it started being finished (`jumpedWith`). -/
def goJumped (driver : TestDriver) (keys : String) : TestDriver :=
  jumpedWith Files.loadJob driver keys

/-- The driver of the jump checks of the files feature after `keys`
(`goJumped`). -/
def goJumpedFrom (keys : String) : Option TestDriver :=
  goDriver.map (goJumped · keys)

end ModelTest
