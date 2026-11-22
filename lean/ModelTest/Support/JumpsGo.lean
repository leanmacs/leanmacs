import Editor.Jumps.Go
import Editor.Test.Hosted
import FilesApiTest.Fake
import ModelTest.Support.Jumps

/-!
# Model tests: support: JumpsGo

The jump checks' driver of going to a place: the keys of the core's jump
support (`ModelTest/Support/Jumps.lean`, `jumpBindings`) bound to the
core's commands, moving through the list and going to a place
(`Jumps.move`, `Jumps.goTo`, `Editor/Jumps/Go.lean`), and to visits of a
file through `files-api`'s fake's `FilesApi.Files` value
(`FilesApiTest.files`), with the fake's jobs; opening a file, switching and
closing a buffer are the core's support's stand-ins (`jumpStandIns`).
`Jumps.Go` is the core's, so this support is too: it names no module of the
files feature, whose visit is held to the same contract
(`FilesApiTest.contractChecks`). Shared by `ModelTest/Editor/Jumps/Go.lean`
and `packages/evil/EvilTest/Evil/Marks.lean`; it holds no checks of its own.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The commands of the jump checks of going to a place: `back`, `forward`
and `go-to`, and `visit` and `visit-quietly` through `files-api`'s fake; and
the core's stand-ins for `open`, `switch`, `close` and `close-1`. -/
def jumpGoCommands : List (String × Dispatched) :=
  let view (call : Call) : ViewId := call.target.window.id
  [
      ("back", jumpCommand fun call => discard <| Jumps.move (view call) (-1)),
      ("forward", jumpCommand fun call => discard <| Jumps.move (view call) 1),
      ("go-to", jumpCommand fun call => Jumps.goTo (view call) (.file jumpsPath 1 0) false),
      ("visit",
        jumpCommand fun call =>
          FilesApiTest.files.visit (view call) jumpsPath
            { row := 1, column := 0, firstNonBlank := true } false true),
      ("visit-quietly",
        jumpCommand fun call =>
          FilesApiTest.files.visit (view call) jumpsPath
            { row := 1, column := 0, firstNonBlank := true } false false),
    ] ++
    -- Opening, switching and closing are the core's stand-ins: the file
    -- and buffer commands are features of their own.
    jumpStandIns

/-- The driver of the jump checks of going to a place: the core's commands
and those of `jumpGoCommands`, `files-api`'s fake's jobs, and its
`FilesApi.Files` value, which going to a place in a closed file visits it
through. -/
def goDriver : Option TestDriver :=
  (jumpDriverWith (jumpCoreCommands ++ jumpGoCommands) FilesApiTest.jobs).map fun driver =>
    { driver with keys := withExtensionsOf driver.keys #[FilesApiTest.fake] }

/-- `driver`, of going to a place, fed the keys `keys`, each followed by
every load it started being finished (`jumpedWith`). -/
def goJumped (driver : TestDriver) (keys : String) : TestDriver :=
  jumpedWith Opener.loadJob driver keys

/-- The driver of the jump checks of going to a place after `keys`
(`goJumped`). -/
def goJumpedFrom (keys : String) : Option TestDriver :=
  goDriver.map (goJumped · keys)

end ModelTest
