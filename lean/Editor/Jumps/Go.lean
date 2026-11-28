import Editor.Jumps
import FilesApi

/-!
# Jumps: going to a place, in an open buffer or a closed file

The upper of the two jump modules (`Editor/Jumps.lean` has the decisions):
what needs a file opened, which it asks of the files through the interface
library `files-api` (`FilesApi.lean`), so that the lower one can be
imported by the files feature. It decides nothing of its own.

- **Going to a place** (`go`): a held place by `Jumps.goHeld`, which
  unfolds a folded range that holds it, and a place
  in a closed file by a visit of the file at its row and column, at the
  row's first non-blank with `line`, through the files implementation's
  `visit` (`FilesApi.files?`). With no files implementation it says
  `FilesApi.noImplementation "jump"` and goes nowhere. The visit passes
  `record := false`: the jump was recorded, or the step was planned, before
  it, and the visit's own record when the load lands would append an entry
  and move the index (Vim's `movemark` opens the file with
  `buflist_getfile`, which sets no previous-context mark).
- **Moving by `n`** (`move`, `C-o` and `C-i`): `Jumps.plan`, then going to
  the place it lands on. The index moves at once, before a file is loaded,
  as Vim's does.
- **Going to a place as a jump** (`goTo`, a mark in another buffer): the
  jump is recorded once, then the place is gone to.

Pinned by `ModelTest.jumpGoChecks`.
-/

namespace Editor.Jumps

/-- The name a jump says a refusal under. -/
def jumpName : String :=
  "jump"

/-- Goes to `place` in `view` ("Going to a place", in the module docs); with
`line`, to the first non-blank of its line. -/
def go (view : ViewId) (place : Place) (line : Bool) : EditorM Unit :=
  match place with
  | .held buffer marker => goHeld view buffer marker line
  | .file path row column => do
    match ← FilesApi.files? with
    | some files =>
      files.visit view path { row, column, firstNonBlank := line } false false
    | none =>
      message (FilesApi.noImplementation jumpName)

/-- Moves `view` by `n` through its jump list ("Moving by `n`", in the
module docs): whether the step was taken. -/
def move (view : ViewId) (n : Int) : EditorM Bool := do
  let some place ← plan view n | return false
  go view place false
  return true

/-- Goes to `place` in `view` as a jump ("Going to a place as a jump", in
the module docs): the jump is recorded, then the place is gone to, with
`line` at its line's first non-blank. -/
def goTo (view : ViewId) (place : Place) (line : Bool) : EditorM Unit := do
  record view
  go view place line

end Editor.Jumps
