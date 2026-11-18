import Editor.Api
import Editor.Event
import Editor.ExcerptView
import Editor.Loop
import Editor.Loop.Driver
import Editor.Scene
import Editor.State
import Editor.Text
import Editor.Text.Model
import Editor.VersionControl
import Editor.VersionControl.Contract
import Editor.VersionControl.Model
import Editor.VersionControl.Review
import Editor.VersionControl.ReviewHunks
import ModelTest.Check
import ModelTest.Editor.VersionControl.ReviewHunks
import ModelTest.Support.Driver
import ModelTest.Support.Files
import ModelTest.Support.Keys
import ModelTest.Support.VersionControl

/-!
# Model tests: `Editor/VersionControl/Review.lean`

The model tests of `Editor/VersionControl/Review.lean`: `reviewBufferChecks`.
The root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.VersionControl

/-- `lean/Pkg/B.lean` on the branch of `reviewRepository`: `twentyLines` with
rows 1 and 15 changed, two hunks. -/
def reviewedB : String :=
  rowsSet twentyLines [(1, "two\n"), (15, "sixteen\n")]

/-- The repository of the review buffer checks: on `main`, whose `HEAD` is
the branch reviewed, forked from `B`, which the branch `base` names.
Against it the branch changes `lean/Pkg/A.lean`, which imports `Pkg.B`, a
line; `lean/Pkg/B.lean`, two hunks; `lean/Pkg/C.lean`, a line added; adds
the test `lean/PkgTest/ATest.lean`; and deletes `lean/Pkg/D.lean`. So the
policy's order is the test, then `B`, `A`, `C` and `D`: not the paths'
order, nor its reverse. -/
def reviewRepository : Model.Repository :=
  VersionControlContract.forked
    #[("lean/Pkg/A.lean", "import Pkg.B\n\ndef a := 1\n"), ("lean/Pkg/B.lean", twentyLines),
      ("lean/Pkg/C.lean", "def c := 1\n"), ("lean/Pkg/D.lean", "def d := 1\n")]
    #[("lean/Pkg/A.lean", "import Pkg.B\n\ndef a := 2\n"), ("lean/Pkg/B.lean", reviewedB),
      ("lean/Pkg/C.lean", "def c := 1\ndef c2 := 2\n"),
      ("lean/PkgTest/ATest.lean", "import Pkg.A\n#eval Pkg.a\n")]
    #[] #[("base", "B")]

/-- The headers of the review buffer of `reviewRepository`, in the policy's
order. -/
def reviewHeadersExpected : Array String :=
  #["lean/PkgTest/ATest.lean @@ -0,0 +1,2 @@", "lean/Pkg/B.lean @@ -1,5 +1,5 @@",
    "lean/Pkg/B.lean @@ -13,7 +13,7 @@", "lean/Pkg/A.lean @@ -1,3 +1,3 @@",
    "lean/Pkg/C.lean @@ -1 +1,2 @@", "lean/Pkg/D.lean @@ -1 +0,0 @@"]

/-- `driver` once every pending job not called `but` is finished, oldest
first, with those they start; bounded. -/
def reviewSettledBut (driver : TestDriver) (but : Option String) : TestDriver :=
  (List.range 24).foldl
    (fun driver _ =>
      match driver.pending.find? (some ·.name != but) with
      | some job => (driver.finish job.id).1
      | none => driver)
    driver

/-- `driver` once `events` are fed and every job they start, and every job
those jobs' commands start, is finished, the review's diff last, so the
scene its command publishes is the last one. -/
def reviewSettledOn (driver : TestDriver) (events : List Event) : TestDriver :=
  reviewSettledBut (reviewSettledBut (fedTo driver events).1 (some reviewDiffJob)) none

/-- `driver` once `keys` are pressed and everything they start settles. -/
def reviewAfter (driver : TestDriver) (keys : String) : TestDriver :=
  reviewSettledOn driver (presses keys)

/-- What the focused view of `driver` shows: the review buffer, once one is
opened. -/
def focusedShowing (driver : TestDriver) : Option Showing :=
  showing driver driver.loop.state.frame.focused

/-- The focused view of the last scene of `driver`. -/
def focusedView (driver : TestDriver) : Option View := do
  (← driver.model.display.scenes.back?).views.find? (·.id == driver.loop.state.frame.focused)

/-- The review buffer of `driver`'s focused view, if it shows one, and its
record. -/
def reviewShown (driver : TestDriver) : Option (BufferId × ReviewRecord) := do
  let shown ← focusedShowing driver
  return (shown.id, ← reviewRecordOf driver.loop.state shown.id)

/-- The headers of the entries of the buffer `driver`'s focused view shows
that are not empty. -/
def shownHeaders (driver : TestDriver) : Array String :=
  (((focusedShowing driver).bind (·.buffer.excerpts)).map fun excerpts =>
        (excerpts.entries.map (·.header)).filter (!·.isEmpty)).getD
    #[]

/-- What the text model holds of `buffer` in `driver`. -/
def fileTextOf (driver : TestDriver) (buffer : Buffer) : Option String :=
  (driver.model.texts.texts[buffer.text.index]?).join.map (·.contents)

/-- What the text model holds of the buffer holding the file `path` in
`driver`. -/
def fileText (driver : TestDriver) (path : System.FilePath) : Option String := do
  let id ← driver.loop.state.findFile path
  let buffer ← driver.loop.state.buffer? id
  (driver.model.texts.texts[buffer.text.index]?).join.map (·.contents)

/-- The list of the review text of `driver`'s focused view, as the text
model places it. -/
def reviewPlaced (driver : TestDriver) : Option (Array Excerpt.Placed) := do
  let shown ← focusedShowing driver
  (shown.buffer.text.excerpts.runModel driver.model.texts).1.toOption

/-- How many scenes have shown each entry of the buffer `driver`'s focused
view shows. -/
def reviewScenes (driver : TestDriver) : Option (Array Nat) := do
  let shown ← focusedShowing driver
  let excerpts ← shown.buffer.excerpts
  return excerpts.entries.map fun entry => (entry.viewed.map (·.scenes)).getD 0

/-- The review field of the status line of the focused view in the last
scene of `driver`. -/
def reviewStatus (driver : TestDriver) : Option String := do
  let view ← focusedView driver
  (view.status.find? (·.text.endsWith "not examined")).map (·.text)

/-- How many hunks the status line of the focused view in the last scene of
`driver` says are not examined. -/
def unexaminedCount (driver : TestDriver) : Option Nat := do
  let text ← reviewStatus driver
  let parts := text.splitOn " · "
  ((← parts[2]?).splitOn " ")[0]?.bind (·.toNat?)

/-- The review-unexamined decorations of the focused view in the last scene
of `driver`. -/
def unexaminedShown (driver : TestDriver) : Array Decoration :=
  ((focusedView driver).map fun view =>
        view.decorations.filter (·.face == ExcerptView.unexaminedFace)).getD
    #[]

/-- How many snapshots `driver`'s text model holds that no view of the last
scene names: none once every step released what it took. -/
def strayShots (driver : TestDriver) : Nat :=
  let named := ((driver.model.display.scenes.back?).map (·.views.map (·.snapshot))).getD #[]
  (driver.model.texts.snapshots.zipIdx.filter fun (snapshot, index) =>
      snapshot.isSome && !named.contains ⟨index⟩).size

/-- The names of the old buffers of `driver`: the buffers whose name has
`@B`, the base of the review buffer checks' repositories. -/
def oldNames (driver : TestDriver) : Array String :=
  ((driver.loop.state.buffers.filterMap id).map (·.name)).filter fun name =>
    (name.splitOn "@B").length > 1

/-- What the workspace at `/r` of `driver` keeps of its reviews. -/
def keptReviews (driver : TestDriver) : ReviewStore :=
  driver.loop.state.workspaces.get reviewStore (.local "/r")

/-- A repository whose branch changes one line of `x.txt`: one hunk. -/
def oneHunkRepository : Model.Repository :=
  VersionControlContract.forked #[("x.txt", "x\n")] #[("x.txt", "y\n")] #[] #[("base", "B")]

/-- The repository of the checks of a review since a commit and of a
commit's review: on `main`, `HEAD` changes `y.txt` over `C`, which changed
`x.txt` over `B`, which the branch `base` names; `Z`, off the branch, is `C`
amended, its subject `C` and its `x.txt` another line. -/
def sinceRepository : Model.Repository :=
  { VersionControlContract.clean
      #[("x.txt", "X\n"),
        ("y.txt",
          "Y\n")] with
    commits :=
      #[("B", { files := #[("x.txt", "x\n"), ("y.txt", "y\n")] }),
        ("C", { parents := #["B"], files := #[("x.txt", "X\n"), ("y.txt", "y\n")] }),
        ("Z",
          { parents := #["B"], files := #[("x.txt", "X2\n"), ("y.txt", "y\n")]
            authored := { Model.fixedAuthored with subject := "C" } })]
    parents := #["C"], branches := #[("base", "B")] }

/-- The name of the buffer holding `text` among `driver`'s that is the
source of an entry of the excerpt buffer its focused view shows, and
whether it is read-only, for each entry. -/
def entrySources (driver : TestDriver) : Array (String × Bool) :=
  let buffers := driver.loop.state.buffers.filterMap id
  (((focusedShowing driver).bind (·.buffer.excerpts)).map fun excerpts =>
        excerpts.entries.filterMap fun entry =>
          (buffers.find? (·.text == entry.source)).map fun buffer =>
            (buffer.name, buffer.readOnly)).getD
    #[]

/-- `reviewRepository`'s driver with `/r/src/a.lean` open in view 0, so the
window's buffer is in the workspace at `/r`. -/
def reviewOpened (repository : Model.Repository := reviewRepository) : Option TestDriver :=
  (reviewDriverOf repository).map (reviewAfter · "C-o a")

/-- The checks of the review buffer (`Editor/VersionControl/Review.lean`), on
the loop's driver over the editor's models, the job model, the file model
and the version-control interface's model, its read over the model
(`Model.readHandler`). -/
def reviewBufferChecks : List Check :=
  [{  name :=
        "criterion 1 on the models: vc-review opens one review buffer of HEAD's change against the named branch, its excerpts' headers in the policy's order (the test file, then B, A, C and D), shown and focused"
      run :=
        pure <|
          match reviewOpened with
          | none => false
          | some opened =>
            let reviewed := reviewAfter opened "C-t r"
            (focusedShowing reviewed).map (·.buffer.name) == some "*vc-review: r@main*" &&
              (showing reviewed).map (·.buffer.name) == some "a.lean" &&
              shownHeaders reviewed == reviewHeadersExpected &&
              (reviewShown reviewed).map (fun (_, record) => (record.against, record.base)) ==
                some ("base", "B") &&
              (focusedShowing reviewed).bind (·.buffer.major) == some reviewModeName &&
              strayShots reviewed == 0 },
    { name :=
        "criterion 2 on the models: vc-review-revert on the first of two hunks of a file makes its buffer hold the base's lines for that hunk and the branch's lines for the other, says so, and u in the review buffer gives the branch's text back"
      run :=
        pure <|
          match reviewOpened with
          | none => false
          | some opened =>
            let reviewed := reviewAfter opened "C-t r"
            -- Excerpt 2 is the new side of B's first hunk.
            let reverted := reviewAfter reviewed "C-t 2 C-t v"
            let undone := reviewAfter reverted "C-t u"
            let path : System.FilePath := "/r/lean/Pkg/B.lean"
            fileText reviewed path == some reviewedB &&
              fileText reverted path == some (rowsSet twentyLines [(15, "sixteen\n")]) &&
              echoOf reverted == some "reverted a hunk of lean/Pkg/B.lean" &&
              fileText undone path == some reviewedB &&
              (reviewShown undone).map (fun (_, record) => record.hunks.map (·.decision)) ==
                some #[.«open», .reverted, .«open», .«open», .«open», .«open»] },
    { name :=
        "vc-review-revert on the hunk of a file the branch adds empties that file's buffer, says so, and leaves the other files' buffers as they were"
      run :=
        pure <|
          match reviewOpened with
          | none => false
          | some opened =>
            let reviewed := reviewAfter opened "C-t r"
            -- Excerpt 0 is the new side of ATest's one hunk, which has no
            -- old side.
            let reverted := reviewAfter reviewed "C-t 0 C-t v"
            let others : List (System.FilePath × String) :=
              [("/r/lean/Pkg/A.lean", "import Pkg.B\n\ndef a := 2\n"),
                ("/r/lean/Pkg/B.lean", reviewedB),
                ("/r/lean/Pkg/C.lean", "def c := 1\ndef c2 := 2\n")]
            fileText reviewed "/r/lean/PkgTest/ATest.lean" == some "import Pkg.A\n#eval Pkg.a\n" &&
              fileText reverted "/r/lean/PkgTest/ATest.lean" == some "" &&
              echoOf reverted == some "reverted a hunk of lean/PkgTest/ATest.lean" &&
              others.all (fun (path, text) => fileText reverted path == some text) &&
              (reviewShown reverted).map (fun (_, record) => record.hunks.map (·.decision)) ==
                some #[.reverted, .«open», .«open», .«open», .«open», .«open»] },
    { name :=
        "criterion 3 on the models: a hunk's excerpt is drawn in review-unexamined in the scene that first shows it and not after, and a hunk below the view is never marked until it is shown"
      run :=
        pure <|
          match reviewOpened with
          | none => false
          | some opened =>
            let reviewed := reviewAfter opened "C-t r"
            let next := reviewAfter reviewed "C-t z"
            let ended := reviewAfter next "C-t 8"
            let after := reviewAfter ended "C-t z"
            match reviewPlaced reviewed, reviewScenes reviewed, reviewScenes ended with
            | some placed, some first, some last =>
              let unexamined (index : Nat) : Option Decoration :=
                placed[index]?.map fun excerpt =>
                  ⟨excerpt.start, excerpt.stop, ExcerptView.unexaminedFace⟩
              first[0]? == some 1 && first.back? == some 0 &&
                (unexamined 0).any (unexaminedShown reviewed).contains &&
                !(unexamined 0).any (unexaminedShown next).contains &&
                last.back? == some 1 &&
                (unexamined (placed.size - 1)).any (unexaminedShown ended).contains &&
                !(unexamined (placed.size - 1)).any (unexaminedShown after).contains
            | _, _, _ => false },
    { name :=
        "criterion 4 on the models: the review buffer's status line says 0 kept · 0 reverted · every hunk not examined, then 1 kept after vc-review-keep, 1 reverted after vc-review-revert, and fewer not examined once the last hunk has been shown"
      run :=
        pure <|
          match reviewOpened with
          | none => false
          | some opened =>
            let reviewed := reviewAfter opened "C-t r"
            let kept := reviewAfter reviewed "C-t 0 C-t k"
            let reverted := reviewAfter kept "C-t 2 C-t v"
            let ended := reviewAfter reverted "C-t 8"
            let after := reviewAfter ended "C-t z"
            reviewStatus reviewed == some "0 kept · 0 reverted · 6 not examined" &&
              (reviewStatus kept).any (·.startsWith "1 kept · 0 reverted · ") &&
              echoOf kept == some "kept a hunk of lean/PkgTest/ATest.lean" &&
              (reviewStatus reverted).any (·.startsWith "1 kept · 1 reverted · ") &&
              (match unexaminedCount reverted, unexaminedCount after with
              | some before, some later => later < before
              | _, _ => false) &&
              (reviewShown kept).map (fun (_, record) => record.hunks[0]?.map (·.headerText)) ==
                some (some "lean/PkgTest/ATest.lean @@ -0,0 +1,2 @@  kept") &&
              shownHeaders kept ==
                #["lean/PkgTest/ATest.lean @@ -0,0 +1,2 @@  kept"] ++
                  reviewHeadersExpected.extract 1 },
    { name :=
        "the gutter of the review buffer marks each added line + in diff.added and each removed line - in diff.removed, at the review text's revision"
      run :=
        pure <|
          match reviewOpened with
          | none => false
          | some opened =>
            let reviewed := reviewAfter opened "C-t r"
            match focusedShowing reviewed, reviewPlaced reviewed with
            | some shown, some placed =>
              let mark (index : Nat) (start stop : Nat) (text : String) (face : FaceName) :
                Option GutterMark :=
                placed[index]?.map fun excerpt =>
                  { start := excerpt.start + start, stop := excerpt.start + stop, text, face }
              let marks := (shown.buffer.gutter.map (·.marks)).getD #[]
              -- ATest's two added lines; B's first hunk: `2` removed, `two`
              -- added, its second row.
              marks.size == 9 &&
                [mark 0 0 25 "+" addedFace, mark 1 0 2 "-" removedFace,
                      mark 2 2 6 "+" addedFace].all
                  (·.any marks.contains)
            | _, _ => false },
    { name := "the refusals before any job: no workspace, and a name that starts with -"
      run :=
        pure <|
          match reviewDriverOf reviewRepository, reviewOpened with
          | some driver, some opened =>
            let bare := reviewAfter driver "C-t r"
            let dashed := reviewAfter opened "C-t d"
            (echoOf bare).any (·.endsWith "has no workspace") &&
              (echoOf bare).any (·.startsWith "vc-review: ") &&
              echoOf dashed == some "vc-review: -x starts with -" &&
              dashed.pending.isEmpty &&
              strayShots dashed == 0
          | _, _ => false },
    { name :=
        "no change against the branch says so; with no name the main worktree's branch is taken, and a detached main worktree is refused"
      run :=
        pure <|
          match reviewOpened, reviewOpened { reviewRepository with head := .detached } with
          | some opened, some detached =>
            echoOf (reviewAfter opened "C-t m") == some "vc-review: no change against main" &&
              echoOf (reviewAfter opened "C-t n") == some "vc-review: no change against main" &&
              echoOf (reviewAfter detached "C-t n") ==
                some "vc-review: the main worktree is detached; name a branch to review against" &&
              strayShots (reviewAfter opened "C-t m") == 0
          | _, _ => false },
    { name := "a file whose load is refused is left out of the review and named once it opens"
      run :=
        pure <|
          let missing :=
            { reviewRepository with
              worktree := reviewRepository.worktree.filter (·.1 != "lean/Pkg/C.lean") }
          match reviewOpened missing with
          | none => false
          | some opened =>
            let reviewed := reviewAfter opened "C-t r"
            shownHeaders reviewed ==
                reviewHeadersExpected.filter (!·.startsWith "lean/Pkg/C.lean") &&
              echoOf reviewed == some "vc-review: left out lean/Pkg/C.lean: its load was refused" &&
              strayShots reviewed == 0 },
    { name := "when every changed file's load is refused, the review names them and opens nothing"
      run :=
        pure <|
          let unread :=
            {
              VersionControlContract.forked #[("x.txt", "x\n")] #[("x.txt", "y\n")] #[]
                #[("base", "B")] with
              worktree := #[] }
          match reviewOpened unread with
          | none => false
          | some opened =>
            let reviewed := reviewAfter opened "C-t r"
            echoOf reviewed == some "vc-review: left out x.txt: its load was refused" &&
              (focusedShowing reviewed).map (·.buffer.name) == some "a.lean" &&
              strayShots reviewed == 0 },
    { name :=
        "a working buffer edited between its snapshot and the diff says so, opens nothing and holds no snapshot"
      run :=
        pure <|
          match reviewOpened with
          | none => false
          | some opened =>
            let (asked, _) := fedTo opened (presses "C-t r")
            let read := finishNamed asked reviewReadJob
            let (edited, _) := fedTo read (presses "C-t e")
            let diffed := reviewSettledOn edited []
            read.pending.any (·.name == reviewDiffJob) &&
              fileText edited "/r/lean/Pkg/B.lean" == some ("0\n" ++ reviewedB) &&
              echoOf diffed ==
                some
                  "vc-review: lean/Pkg/B.lean changed while the review was read; run vc-review again" &&
              (showing diffed).map (·.buffer.name) == some "a.lean" &&
              strayShots diffed == 0 },
    { name :=
        "a round that ends before its review buffer is built removes the old buffers it made: a working buffer edited while the review was read, and a refresh once every hunk is reverted"
      run :=
        pure <|
          match reviewOpened, reviewOpened oneHunkRepository with
          | some opened, some single =>
            let (asked, _) := fedTo opened (presses "C-t r")
            let read := finishNamed asked reviewReadJob
            let (edited, _) := fedTo read (presses "C-t e")
            let diffed := reviewSettledOn edited []
            let reviewed := reviewAfter single "C-t r"
            -- Excerpt 1 is the new side of x.txt's one hunk.
            let reverted := reviewAfter reviewed "C-t 1 C-t v"
            let refreshed := reviewAfter reverted "C-t f"
            oldNames read ==
                #["lean/Pkg/A.lean@B", "lean/Pkg/B.lean@B", "lean/Pkg/C.lean@B",
                  "lean/Pkg/D.lean@B"] &&
              oldNames diffed == #[] &&
              fileText reverted "/r/x.txt" == some "x\n" &&
              echoOf refreshed == some "vc-review: no change against base" &&
              oldNames reviewed == #["x.txt@B"] &&
              oldNames refreshed == oldNames reviewed &&
              strayShots refreshed == 0
          | _, _ => false },
    { name :=
        "keep and revert outside a review buffer say so; revert of a deleted file's hunk says there is nothing to revert into; a record with no hunk on the line says so"
      run :=
        pure <|
          match reviewOpened with
          | none => false
          | some opened =>
            let reviewed := reviewAfter opened "C-t r"
            let deleted := reviewAfter reviewed "C-t 8 C-t v"
            let blank := reviewAfter reviewed "C-t x C-t k"
            echoOf (reviewAfter opened "C-t k") ==
                some "vc-review-keep: a.lean is not a review buffer" &&
              echoOf (reviewAfter opened "C-t v") ==
                some "vc-review-revert: a.lean is not a review buffer" &&
              echoOf (reviewAfter opened "C-t f") ==
                some "vc-review-refresh: a.lean is not a review buffer" &&
              echoOf deleted ==
                some
                  "vc-review-revert: lean/Pkg/D.lean is deleted on the branch; nothing to revert into" &&
              echoOf blank == some "vc-review: no hunk on this line" },
    { name :=
        "vc-review-refresh reads the change again into the same buffer, removes the last round's old buffers no window shows, and adds a round to the store"
      run :=
        pure <|
          match reviewOpened with
          | none => false
          | some opened =>
            let reviewed := reviewAfter opened "C-t r"
            let refreshed := reviewAfter reviewed "C-t f"
            let olds (driver : TestDriver) : Nat :=
              ((driver.loop.state.buffers.filterMap id).filter fun buffer =>
                  (buffer.name.splitOn "@B").length > 1).size
            let rounds (driver : TestDriver) : Nat :=
              (driver.loop.state.workspaces.get reviewStore (.local "/r")).rounds.size
            (reviewShown refreshed).map (·.1) == (reviewShown reviewed).map (·.1) &&
              shownHeaders refreshed == reviewHeadersExpected &&
              olds reviewed == 4 &&
              olds refreshed == 4 &&
              (reviewShown reviewed).map (·.2.olds) != (reviewShown refreshed).map (·.2.olds) &&
              rounds reviewed == 1 &&
              rounds refreshed == 2 &&
              strayShots refreshed == 0 },
    { name :=
        "keep and revert rewrite the store's last round in place: after vc-review-keep it holds one round, its first hunk kept and that hunk's viewed records showing it was on screen, a hunk never shown not; after vc-review-revert still one round"
      run :=
        pure <|
          match reviewOpened with
          | none => false
          | some opened =>
            let reviewed := reviewAfter opened "C-t r"
            let kept := reviewAfter reviewed "C-t 0 C-t k"
            let reverted := reviewAfter kept "C-t 2 C-t v"
            match (keptReviews kept).rounds, (keptReviews reverted).rounds with
            | #[round], #[later] =>
              round.hunks.map (·.decision) ==
                  #[.kept, .«open», .«open», .«open», .«open», .«open»] &&
                (round.against, round.base) == ("base", "B") &&
                (round.hunks[0]?.any fun hunk =>
                  !hunk.viewed.isEmpty && hunk.viewed.all (·.examined)) &&
                (round.hunks.back?.any fun hunk =>
                  !hunk.viewed.isEmpty && hunk.viewed.all (!·.examined)) &&
                later.hunks.map (·.decision) ==
                  #[.kept, .reverted, .«open», .«open», .«open», .«open»] &&
                (keptReviews reverted).buffer == (reviewShown reverted).map (·.1.index)
            | _, _ => false },
    { name :=
        "the store keeps the last Review.keptRounds (20) rounds: a fresh round past them drops the oldest"
      run :=
        pure <|
          match reviewOpened with
          | none => false
          | some opened =>
            let record (round : Nat) : ReviewRecord :=
              { root := "/r", against := s!"b{round}", base := "B" }
            let written :=
              dispatchedFrom (start := pure opened.loop.state) do
                for round in List.range (Review.keptRounds + 1) do
                  writeRound ⟨0⟩ (record round) true
            Review.keptRounds == 20 &&
              written.any fun (_, state) =>
                let kept := state.workspaces.get reviewStore (.local "/r")
                kept.rounds.map (·.against) ==
                    ((List.range 20).map fun round => s!"b{round + 1}").toArray &&
                  kept.buffer == some 0 },
    { name :=
        "criterion 4's record: after vc-review the record and the store's round hold the commit HEAD was at, the model's HEAD id, and keep keeps it"
      run :=
        pure <|
          match reviewOpened with
          | none => false
          | some opened =>
            let reviewed := reviewAfter opened "C-t r"
            let kept := reviewAfter reviewed "C-t 0 C-t k"
            (reviewShown reviewed).map (·.2.head) == some "head" &&
              (reviewShown reviewed).map (·.2.scope) == some .branch &&
              (keptReviews reviewed).rounds.map (·.head) == #["head"] &&
              (keptReviews kept).rounds.map (·.head) == #["head"] },
    { name :=
        "a round decodes to what it encodes, the commit it was made at kept; the store is at version 2, and migrates a version-1 tree to one whose rounds recorded no commit"
      run :=
        pure <|
          let round : ReviewStore.Round :=
            { against := "base", base := "B", head := "H"
              hunks :=
                #[{ path := "a", header := "a @@ -1 +1 @@", decision := .kept, viewed := #[{}] }] }
          let older : Value :=
            .record
              [("buffer", .nat 3),
                ("rounds",
                  .list
                    [.record
                        [("against", .str "base"), ("base", .str "B"),
                          ("hunks", .list (round.hunks.toList.map (·.encode)))]])]
          ReviewStore.Round.decode? round.encode == some round && reviewStore.version == 2 &&
            ((reviewStore.migrate 1 older).bind reviewStore.decode) ==
              some { buffer := some 3, rounds := #[{ round with head := "" }] } &&
            reviewStore.migrate 2 older == none },
    { name :=
        "visiting a commit opens its change as a review buffer: its hunks against its first parent alone, its new side read-only buffers of the commit's content and the working file never taken in, keep recorded and no round written, revert refused; a root commit's files are each added"
      run :=
        pure <|
          match reviewOpened sinceRepository with
          | none => false
          | some opened =>
            let reviewed := reviewAfter opened "C-y m"
            let kept := reviewAfter reviewed "C-t 1 C-t k"
            let reverted := reviewAfter reviewed "C-t 1 C-t v"
            let root := reviewAfter opened "C-y b"
            (focusedShowing reviewed).map (·.buffer.name) == some "*vc-review: r@main C*" &&
              shownHeaders reviewed == #["x.txt @@ -1 +1 @@"] &&
              entrySources reviewed == #[("x.txt@B", true), ("x.txt@C", true)] &&
              (reviewShown reviewed).map (fun (_, record) => (record.scope, record.head)) ==
                some (.commit "C", "C") &&
              echoOf kept == some "kept a hunk of x.txt" &&
              (keptReviews kept).rounds.isEmpty &&
              echoOf reverted ==
                some "vc-review-revert: this review is of commit C; nothing to revert" &&
              -- The working file is never taken in.
              fileText reverted "/r/x.txt" == none &&
              (focusedShowing root).map (·.buffer.name) == some "*vc-review: r@main B*" &&
              shownHeaders root == #["x.txt @@ -0,0 +1 @@", "y.txt @@ -0,0 +1 @@"] &&
              entrySources root == #[("x.txt@B", true), ("y.txt@B", true)] &&
              strayShots reviewed == 0 },
    { name :=
        "a commit's review holds its new side's read-only buffers in its record's olds, so a refresh leaves one of each and a round that ends before its buffer is built removes them"
      run :=
        pure <|
          let refusing (name : String) : Option (List Argument → Work) :=
            if name == reviewDiffJob then none else reviewJobs sinceRepository name
          match reviewOpened sinceRepository,
            (reviewDriverOf sinceRepository (registered := refusing)).map
              (reviewAfter · "C-o a") with
          | some opened, some refused =>
            let reviewed := reviewAfter opened "C-y m"
            let refreshed := reviewAfter reviewed "C-t f"
            let ended := reviewAfter refused "C-y m"
            -- The buffers of x.txt at C: the commit's new side.
            let newSides (driver : TestDriver) : Array Nat :=
              driver.loop.state.buffers.zipIdx.filterMap fun (buffer, index) =>
                buffer.bind fun buffer =>
                  if buffer.name.startsWith "x.txt@C" then some index else none
            let held (driver : TestDriver) : Bool :=
              (reviewShown driver).any fun (_, record) => (newSides driver).all record.olds.contains
            (newSides reviewed).size == 1 && held reviewed && (newSides refreshed).size == 1 &&
              held refreshed &&
              strayShots refreshed == 0 &&
              (echoOf ended).any (·.startsWith "vc-review: ") &&
              newSides ended == #[] &&
              oldNames ended == #[] &&
              strayShots ended == 0
          | _, _ => false },
    { name :=
        "criterion 4 on the models: with the last round at an earlier commit of the branch, vc-review-since opens the change since it, the later commits' hunks alone, and records a round against the same branch at the new HEAD"
      run :=
        pure <|
          match reviewOpened sinceRepository with
          | none => false
          | some opened =>
            let since := reviewAfter (reviewAfter opened "C-y c") "C-y s"
            (focusedShowing since).map (·.buffer.name) == some "*vc-review: r@main since C*" &&
              shownHeaders since == #["y.txt @@ -1 +1 @@"] &&
              (reviewShown since).map
                  (fun (_, record) => (record.scope, record.base, record.head)) ==
                some (.since "C", "C", "head") &&
              (keptReviews since).rounds.map (fun round => (round.against, round.head)) ==
                #[("base", "C"), ("base", "head")] &&
              (entrySources since).map (·.1) == #["y.txt@C", "y.txt"] &&
              strayShots since == 0 },
    { name :=
        "a working buffer edited between the read of a review since a commit and its diff says so as vc-review-since, names vc-review-since to run again, and opens nothing"
      run :=
        pure <|
          match reviewOpened sinceRepository with
          | none => false
          | some opened =>
            let seeded := reviewAfter opened "C-y c"
            let (asked, _) := fedTo seeded (presses "C-y s")
            let read := finishNamed asked reviewReadJob
            let (edited, _) := fedTo read (presses "C-y e")
            let diffed := reviewSettledOn edited []
            read.pending.any (·.name == reviewDiffJob) &&
              fileText edited "/r/y.txt" == some "0\nY\n" &&
              echoOf diffed ==
                some
                  "vc-review-since: y.txt changed while the review was read; run vc-review-since again" &&
              (showing diffed).map (·.buffer.name) == some "a.lean" &&
              strayShots diffed == 0 },
    { name :=
        "with the last round at a commit HEAD was rewritten past, vc-review-since opens the range-diff of the branch's commits since then as text, read-only, and focused"
      run :=
        pure <|
          match reviewOpened sinceRepository with
          | none => false
          | some opened =>
            let since := reviewAfter (reviewAfter opened "C-y z") "C-y s"
            match focusedShowing since with
            | none => false
            | some shown =>
              shown.buffer.name == "*vc-range-diff: r@main*" && shown.buffer.readOnly &&
                fileTextOf since shown.buffer ==
                  some
                    ("r@main: HEAD was rewritten since Z; its commits against base\n" ++
                      "1:  Z ! 1:  C C\n" ++
                      "-:  ------- > 2:  head head\n") },
    { name :=
        "vc-review-since with no round, with a round that recorded no commit, and with HEAD still at the recorded commit says so and opens nothing"
      run :=
        pure <|
          match reviewOpened sinceRepository with
          | none => false
          | some opened =>
            let none_ := reviewAfter opened "C-y s"
            let empty := reviewAfter (reviewAfter opened "C-y 0") "C-y s"
            let still := reviewAfter (reviewAfter opened "C-y h") "C-y s"
            echoOf none_ == some "vc-review-since: no review of r@main is recorded" &&
              echoOf empty ==
                some "vc-review-since: the last review of r@main recorded no commit" &&
              echoOf still == some "vc-review-since: no change since head" &&
              [none_, empty, still].all fun driver =>
                (focusedShowing driver).map (·.buffer.name) == some "a.lean" },
    { name :=
        "an edit typed in a new excerpt changes the file's buffer, and one typed in an old excerpt is refused as read-only"
      run :=
        pure <|
          match reviewOpened with
          | none => false
          | some opened =>
            let reviewed := reviewAfter opened "C-t r"
            let typed := reviewAfter reviewed "C-t 0 C-t i"
            let refused := reviewAfter reviewed "C-t 1 C-t i"
            fileText typed "/r/lean/PkgTest/ATest.lean" == some "Ximport Pkg.A\n#eval Pkg.a\n" &&
              fileText refused "/r/lean/Pkg/B.lean" == some reviewedB &&
              (echoOf refused).any (·.endsWith "lean/Pkg/B.lean@B is read-only") }]

end ModelTest
