import Editor.Diff.Script
import VcApi

/-!
# Hunks to stage

What staging and unstaging a hunk (`Editor/VersionControl/Stage.lean`)
decides beyond the port's own hunk helpers, which make a `LineHunk` of a
`Diff.Hunk` and are the interface's (`VcApi.lean`, "Hunks"):

- **The hunk on a line** (`Hunks.pick`), a line `[start, stop)` of the new
  text: the first hunk whose new range overlaps it; otherwise a removal
  (an empty new range) at its start, where the gutter draws its `-`;
  otherwise a removal at the text's end when the line is the last.
- **A line carried to the old text** (`Hunks.toOld`): outside every hunk
  it is shifted by the sizes of the hunks before it; inside one it is
  that hunk's old range. So the cursor's line of a buffer is carried to a
  line of the index, to pick among the hunks of the index against
  `HEAD`.

Pinned by `ModelTest.hunkChecks`.
-/

namespace Editor.VersionControl

/-- The hunk among `hunks` on the line `[start, stop)` of their new text, whose
length is `size` ("The hunk on a line", in the module docs). -/
def Hunks.pick (hunks : Diff.Hunks) (start stop size : Nat) : Option Diff.Hunk :=
  let removal (hunk : Diff.Hunk) := hunk.newStart == hunk.newStop
  (hunks.find? fun hunk => !removal hunk && hunk.newStart < stop && start < hunk.newStop) <|>
    (hunks.find? fun hunk => removal hunk && hunk.newStart == start) <|>
    hunks.find? fun hunk => removal hunk && stop == size && hunk.newStart == size

/-- The line `[start, stop)` of the new text of `hunks` carried to their old
text ("A line carried to the old text", in the module docs). -/
def Hunks.toOld (hunks : Diff.Hunks) (start stop : Nat) : Nat × Nat :=
  match
    hunks.find? fun hunk =>
      hunk.newStart < stop && start < hunk.newStop ||
        hunk.newStart == hunk.newStop && hunk.newStart == start && start == stop with
  | some hunk => (hunk.oldStart, hunk.oldStop)
  | none =>
    let shift : Int :=
      (hunks.filter (·.newStop ≤ start)).foldl
        (fun shift hunk =>
          shift + ((hunk.oldStop - hunk.oldStart : Nat) : Int) -
            ((hunk.newStop - hunk.newStart : Nat) : Int))
        0
    ((start + shift).toNat, (stop + shift).toNat)

end Editor.VersionControl
