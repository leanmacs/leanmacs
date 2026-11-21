import Editor.Diff.Script
import Editor.State
import Editor.Text
import Editor.Value
import VcApi
import VersionControl.Hunk

/-!
# Review hunks: what a review buffer shows, in what order, and its record

The pure core of the review buffer (`VersionControl/Review.lean`):
how a change's line hunks become review hunks with their context, the order
the files are shown in, and the record of a review and what it says.

## The rules

- **A hunk is git's hunk.** The diff service gives runs of changed whole
  lines (`Diff.Hunks`, `Editor/Diff.lean`). Each run takes `Hunk.context`
  rows of context on each side (`VersionControl/Hunk.lean`),
  clamped at the text's ends, and runs whose context rows overlap or touch
  are one span (`ReviewSpan`), as git merges them: two changes 6 equal rows
  apart are one span, 7 apart two. So two spans of one text are always a
  row apart, and two excerpts of one source never meet.
- **Rows** are counted from 0, in line feeds; a last line with no line
  feed is a row. A side's lines are the rows from its first context row
  up to, not including, its last.
- **The ranges**, in bytes of each text: the span with its context on each
  side (`oldStart`, `oldStop`, `newStart`, `newStop`), and each run's
  removed and added lines (`removed`, `added`), none empty.
- **The numbers** are git's (`ReviewSpan.numbers`): `@@ -a,b +c,d @@`,
  each side's first context line from 1 and its count, a count of 1 left
  out, and an empty side numbered by the line before it with 0. An added
  file is `-0,0`, a deleted one `+0,0`. The header is the path, a space and
  the numbers (`ReviewSpan.header`).
- **The old excerpt** (`ReviewSpan.oldExcerpt?`) is the first removed
  line's start to the last removed line's stop, the context between runs
  included; none when nothing is removed. **The new excerpt** is the new
  side with its context.
- **Changed lines** (`ReviewSpan.changed`) are the rows each run removes
  and adds.
- The grouping walks a `Lines` of each text (`ReviewSpan.group`), so it is
  pinned on strings (`Lines.ofText`) and runs on snapshots in the editor.

## The order

`orderFiles` orders a change's files, each with the lines its hunks change,
by a policy of Lean's, never alphabetical: a reviewer's attention follows
position (`docs/design/review-and-navigation.md`, "Hunk ordering").

- **Tests first** (`isTest`): a path with a `/`-component `test`, `tests`
  or `spec`, or whose file stem ends in `Test`, `Tests`, `_test`, `_tests`,
  `.test` or `.spec`, or starts with `test_`. Then the rest.
- **Within each group, dependencies first.** A file depends on another of
  its group when its text holds the other's module name (`moduleName`) as
  a whole word (`dependsOn`): for a `.lean` path, the dotted module from its
  first component that starts with a capital letter; otherwise the file
  stem, or the directory's name for `mod`, `lib`, `main` and `index`. The
  text is the new one, or the old one of a deleted file: the review hands
  the working buffer's text it shows, not the committed one.
- **Kahn's order**: among the files ready (each it depends on placed), the
  one with more changed lines comes first, then the path, only to make the
  order total. A cycle takes the first remaining file by that tie-break.
- **A file's hunks stay together**, top to bottom: the order is of files.
- The changed lines are the caller's: the review counts them from the
  spans its buffer shows, so the order follows the diff the buffer shows,
  whichever engine made it.

rdm:roadmap/acp-agents replaces this with the order of an agent's plan
steps.

## The record

- **A hunk** (`ReviewHunk`) is its path, its header, the indexes of its
  old and new excerpts in the review buffer's list, where its old side with
  context is in the old buffer, and its decision (`Decision`): open, kept or
  reverted. Its header text (`ReviewHunk.headerText`) is the header and,
  once decided, two spaces and the decision.
- **A record** (`ReviewRecord`) is the root, the branch reviewed against,
  the merge base, the hunks, the read-only buffers the round made that a
  hunk reads (the old buffers, and a commit's new ones), what the review is
  of (`ReviewScope`: a branch against its base, `HEAD` since a recorded
  commit, or one commit against its first parent) and the commit it was
  made at (`head`: the id `HEAD`, or the commit, resolved to when the change
  was read). It is a value of the review buffer, `vc-review`
  (`ReviewRecord.localName`), and a tree (`ReviewRecord.encode`).
- **A hunk is examined** (`ReviewHunk.examined`) when each excerpt it
  names has an entry a scene has shown (`Buffer.Viewed.examined`); an
  entry that is not tracked never was.
- **The counts** (`Review.counts`) are the hunks kept, reverted and not
  examined, and the status line says them as `<k> kept · <r> reverted · <n>
  not examined` (`Review.statusText`).
- **The hunk at an offset** (`Review.hunkAt`) is the one with the first
  excerpt that holds it, both ends included, so a separator row, which
  starts at the end of the excerpt above, is the hunk above's.

Pinned by `VersionControlTest.reviewHunkChecks`, `VersionControlTest.reviewOrderChecks` and
`VersionControlTest.reviewRecordChecks`.
-/

namespace Editor.VersionControl

/-! ## The rules -/

/-- The row a range that stops at `offset` of `lines` stops before: the row
of `offset` when one starts there, and the next row when `offset` is inside
one, at the end of a text with no last line feed. -/
def Lines.rowStop {m : Type → Type} [Monad m] (lines : Lines m) (offset : Nat) : m Nat := do
  let row ← lines.rowOf offset
  if (← lines.startOf row) == offset then
    return row
  else
    return row + 1

/-- One review hunk of a file: one or more runs of changed lines with their
context, in bytes of the old and the new text ("The rules", in the module
docs). -/
structure ReviewSpan where
  /-- Where the old side starts, its context included. -/
  oldStart : Nat
  /-- Where it stops. -/
  oldStop : Nat
  /-- Where the new side starts, its context included. -/
  newStart : Nat
  /-- Where it stops. -/
  newStop : Nat
  /-- Each run's removed lines, in old bytes; none empty. -/
  removed : Array (Nat × Nat) := #[]
  /-- Each run's added lines, in new bytes; none empty. -/
  added : Array (Nat × Nat) := #[]
  /-- The old side's first line, git's number. -/
  oldLine : Nat
  /-- How many lines the old side has. -/
  oldCount : Nat
  /-- The new side's first line, git's number. -/
  newLine : Nat
  /-- How many lines the new side has. -/
  newCount : Nat
  /-- How many rows its runs remove and add. -/
  changed : Nat
  deriving DecidableEq, Repr

/-- One run of changed lines, in rows, with the rows of its context. -/
structure ReviewRun where
  /-- The old side's first context row. -/
  oldFirst : Nat
  /-- The row after its last. -/
  oldLast : Nat
  /-- The new side's first context row. -/
  newFirst : Nat
  /-- The row after its last. -/
  newLast : Nat
  /-- The runs' removed lines, in old bytes. -/
  removed : Array (Nat × Nat)
  /-- The runs' added lines, in new bytes. -/
  added : Array (Nat × Nat)
  /-- The rows removed and added. -/
  changed : Nat

/-- A side's range in git's numbers: the line alone for one line. -/
def gitRange (line count : Nat) : String :=
  if count == 1 then s!"{line}" else s!"{line},{count}"

/-- The span's numbers, `@@ -a,b +c,d @@` ("The rules", in the module
docs). -/
def ReviewSpan.numbers (span : ReviewSpan) : String :=
  s!"@@ -{gitRange span.oldLine span.oldCount} +{gitRange span.newLine span.newCount} @@"

/-- The span's header: `path`, a space and its numbers. -/
def ReviewSpan.header (span : ReviewSpan) (path : String) : String :=
  s!"{path} {span.numbers}"

/-- The old excerpt: the first removed line's start to the last removed
line's stop; none when nothing is removed. -/
def ReviewSpan.oldExcerpt? (span : ReviewSpan) : Option (Nat × Nat) := do
  let first ← span.removed[0]?
  let last ← span.removed.back?
  return (first.1, last.2)

/-- The review spans of `hunks`, the line hunks of `old` against `new` ("The
rules", in the module docs): each run with its context, runs whose context
rows overlap or touch merged. Equal texts give none. -/
def ReviewSpan.group {m : Type → Type} [Monad m] (old new : Lines m) (hunks : Diff.Hunks) :
    m (Array ReviewSpan) := do
  let oldLines ← old.rowStop old.size
  let newLines ← new.rowStop new.size
  let mut runs : Array ReviewRun := #[]
  for hunk in hunks do
    let oldTop ← old.rowStop hunk.oldStart
    let oldBottom ← old.rowStop hunk.oldStop
    let newTop ← new.rowStop hunk.newStart
    let newBottom ← new.rowStop hunk.newStop
    let before := min Hunk.context (min oldTop newTop)
    let after := min Hunk.context (min (oldLines - oldBottom) (newLines - newBottom))
    let run : ReviewRun :=
      { oldFirst := oldTop - before, oldLast := oldBottom + after, newFirst := newTop - before
        newLast := newBottom + after
        removed := if hunk.oldStart < hunk.oldStop then #[(hunk.oldStart, hunk.oldStop)] else #[]
        added := if hunk.newStart < hunk.newStop then #[(hunk.newStart, hunk.newStop)] else #[]
        changed := (oldBottom - oldTop) + (newBottom - newTop) }
    runs :=
      match runs.back? with
      | some last =>
        if run.oldFirst ≤ last.oldLast then
          runs.pop.push
            { last with
              oldLast := run.oldLast, newLast := run.newLast, removed := last.removed ++ run.removed
              added := last.added ++ run.added, changed := last.changed + run.changed }
        else runs.push run
      | none => runs.push run
  runs.mapM fun run => do
      let oldCount := run.oldLast - run.oldFirst
      let newCount := run.newLast - run.newFirst
      return {
          oldStart := ← old.startOf run.oldFirst, oldStop := ← old.startOf run.oldLast
          newStart := ← new.startOf run.newFirst, newStop := ← new.startOf run.newLast
          removed := run.removed, added := run.added
          oldLine := if oldCount == 0 then run.oldFirst else run.oldFirst + 1, oldCount
          newLine := if newCount == 0 then run.newFirst else run.newFirst + 1, newCount
          changed := run.changed }

/-! ## The order -/

/-- The `/`-components of `path`. -/
def pathComponents (path : String) : List String :=
  (path.splitOn "/").filter (!·.isEmpty)

/-- The last component of `path` without its last extension. -/
def fileStem (path : String) : String :=
  let name := ((pathComponents path).getLast?).getD ""
  match name.splitOn "." with
  | [] | [_] => name
  | parts => ".".intercalate parts.dropLast

/-- Whether `path` is a test ("The order", in the module docs). -/
def isTest (path : String) : Bool :=
  let stem := fileStem path
  (pathComponents path).any (fun part => part == "test" || part == "tests" || part == "spec") ||
    ["Test", "Tests", "_test", "_tests", ".test", ".spec"].any
      (fun (suffix : String) => stem.endsWith suffix) ||
    stem.startsWith "test_"

/-- The module `path` names ("The order", in the module docs). -/
def moduleName (path : String) : String :=
  let parts := pathComponents path
  if path.endsWith ".lean" then
    match parts.dropWhile fun part => !(part.front.isUpper) with
    | [] => fileStem path
    | named => ".".intercalate (named.dropLast ++ [fileStem path])
  else
    let stem := fileStem path
    if ["mod", "lib", "main", "index"].contains stem then
      match parts.dropLast.getLast? with
      | some directory => directory
      | none => stem
    else stem

/-- Whether `c` is a character of a word: a letter, a digit or `_`. -/
def wordChar (c : Char) : Bool :=
  c.isAlphanum || c == '_'

/-- Whether `text` holds `word` as a whole word: with no character of a word
just before it or just after it. -/
def holdsWord (text word : String) : Bool :=
  if word.isEmpty then false
  else
    let pieces := text.splitOn word
    let pairs := pieces.zip pieces.tail
    pairs.any fun (before, after) =>
      !(before.toList.getLast?.any wordChar) && !(after.toList.head?.any wordChar)

/-- Whether the file `a` depends on `b` ("The order", in the module docs):
another file, whose module name `a`'s text holds as a whole word; the text
is the new one, or the old one of a deleted file. -/
def dependsOn (a b : FileChange) : Bool :=
  a.path != b.path && holdsWord (a.new.getD (a.old.getD "")) (moduleName b.path)

/-- The indexes of `files`, each a file and the lines its hunks change, in
the policy's order ("The order", in the module docs). -/
def Review.order (files : Array (FileChange × Nat)) : Array Nat :=
  let ranked (i j : Nat) : Bool :=
    match files[i]?, files[j]? with
    | some (a, changedA), some (b, changedB) =>
      changedA > changedB || (changedA == changedB && a.path < b.path)
    | _, _ => i < j
  let depends (i j : Nat) : Bool :=
    match files[i]?, files[j]? with
    | some (a, _), some (b, _) => dependsOn a b
    | _, _ => false
  let place (members : Array Nat) : Array Nat :=
    Id.run do
      let mut placed : Array Nat := #[]
      let mut left := members
      for _ in members do
        let ready := left.filter fun i => left.all fun j => j == i || !depends i j
        let pool := if ready.isEmpty then left else ready
        match pool[0]? with
        | none =>
          pure ()
        | some first =>
          let best := pool.foldl (fun best i => if ranked i best then i else best) first
          placed := placed.push best
          left := left.erase best
      return placed
  let indexes := (List.range files.size).toArray
  let test (i : Nat) : Bool := (files[i]?.map (isTest ·.1.path)).getD false
  place (indexes.filter test) ++ place (indexes.filter (!test ·))

/-- `files` in the policy's order (`Review.order`). -/
def orderFiles (files : Array (FileChange × Nat)) : Array (FileChange × Nat) :=
  (Review.order files).filterMap (files[·]?)

/-! ## The record -/

/-- What was decided of a hunk. -/
inductive Decision where
  /-- Nothing yet. -/
  | «open»
  /-- It is kept as the branch has it. -/
  | kept
  /-- It was reverted to the base's text. -/
  | reverted
  deriving DecidableEq, Repr

/-- The word a decision is written as, in a header and a record. -/
def Decision.word : Decision → String
  | .«open» => "open"
  | .kept => "kept"
  | .reverted => "reverted"

/-- The decision `word` writes (`Decision.word`), if it writes one. -/
def Decision.ofWord? (word : String) : Option Decision :=
  [Decision.«open», .kept, .reverted].find? (·.word == word)

/-- One hunk of a review ("The record", in the module docs). -/
structure ReviewHunk where
  /-- Its file's path, relative to the root. -/
  path : String
  /-- Its header: the path and the numbers, without the decision. -/
  header : String
  /-- Its old excerpt's index in the review buffer's list, when it removes
  lines. -/
  old? : Option Nat := none
  /-- Its new excerpt's index, when the file exists on the branch. -/
  new? : Option Nat := none
  /-- The number of the old buffer its old side is in, when the file has
  one. -/
  oldBuffer? : Option Nat := none
  /-- Where its old side, context included, starts in the old buffer. -/
  oldStart : Nat := 0
  /-- Where it stops. -/
  oldStop : Nat := 0
  /-- What was decided. -/
  decision : Decision := .«open»
  deriving DecidableEq, Repr

/-- The header drawn above the hunk: its header, and two spaces and the
decision once one is made. -/
def ReviewHunk.headerText (hunk : ReviewHunk) : String :=
  match hunk.decision with
  | .«open» => hunk.header
  | decision => s!"{hunk.header}  {decision.word}"

/-- The excerpt indexes the hunk names: its old one, then its new one. -/
def ReviewHunk.excerpts (hunk : ReviewHunk) : Array Nat :=
  hunk.old?.toArray ++ hunk.new?.toArray

/-- Whether every excerpt of the hunk has an entry among `entries` that a
scene has shown ("The record", in the module docs). -/
def ReviewHunk.examined (hunk : ReviewHunk) (entries : Array Buffer.ExcerptEntry) : Bool :=
  hunk.excerpts.all fun index => ((entries[index]?.bind (·.viewed)).map (·.examined)).getD false

/-- What a review is of ("The record", in the module docs). -/
inductive ReviewScope where
  /-- `HEAD` against its merge base with the branch reviewed against, its new
  side the working files. -/
  | branch
  /-- `HEAD` against `commit`, the commit an earlier review recorded, its new
  side the working files. -/
  | since (commit : String)
  /-- The commit `id` against its first parent, its new side read-only
  buffers of the commit's content. -/
  | commit (id : String)
  deriving DecidableEq, Repr

/-- A scope as a tree. -/
def ReviewScope.encode : ReviewScope → Value
  | .branch => .str "branch"
  | .since recorded => .record [("since", .str recorded)]
  | .commit id => .record [("commit", .str id)]

/-- The scope a tree is (`ReviewScope.encode`), if it is one. -/
def ReviewScope.decode? : Value → Option ReviewScope
  | .str "branch" => some .branch
  | .record [("since", .str recorded)] => some (.since recorded)
  | .record [("commit", .str id)] => some (.commit id)
  | _ => none

/-- The record of a review ("The record", in the module docs). -/
structure ReviewRecord where
  /-- The repository's root. -/
  root : String
  /-- The branch reviewed against. -/
  against : String
  /-- The merge base's id. -/
  base : String
  /-- The hunks, in the buffer's order. -/
  hunks : Array ReviewHunk := #[]
  /-- The numbers of the read-only buffers the round made that a hunk
  reads: the old buffers, and a commit's new ones. -/
  olds : Array Nat := #[]
  /-- What the review is of. -/
  scope : ReviewScope := .branch
  /-- The commit `HEAD`, or the commit reviewed, was when its change was
  read; empty for none recorded. -/
  head : String := ""
  deriving DecidableEq, Repr

/-- The name of the review buffer's value that holds its record. -/
def ReviewRecord.localName : String :=
  "vc-review"

/-- An optional number as a tree. -/
def encodeIndex : Option Nat → Value
  | some index => .nat index
  | none => .null

/-- The optional number a tree is (`encodeIndex`), if it is one. -/
def decodeIndex? : Value → Option (Option Nat)
  | .nat index => some (some index)
  | .null => some none
  | _ => none

/-- A hunk as a tree. -/
def ReviewHunk.encode (hunk : ReviewHunk) : Value :=
  .record
    [("path", .str hunk.path), ("header", .str hunk.header), ("old", encodeIndex hunk.old?),
      ("new", encodeIndex hunk.new?), ("oldBuffer", encodeIndex hunk.oldBuffer?),
      ("oldStart", .nat hunk.oldStart), ("oldStop", .nat hunk.oldStop),
      ("decision", .str hunk.decision.word)]

/-- The hunk a tree is (`ReviewHunk.encode`), if it is one. -/
def ReviewHunk.decode? : Value → Option ReviewHunk
  |
  .record
      [("path", .str path), ("header", .str header), ("old", old), ("new", new),
        ("oldBuffer", oldBuffer), ("oldStart", .nat oldStart), ("oldStop", .nat oldStop),
        ("decision", .str decision)] =>
    do
    return {
        path, header, old? := ← decodeIndex? old, new? := ← decodeIndex? new
        oldBuffer? := ← decodeIndex? oldBuffer, oldStart, oldStop
        decision := ← Decision.ofWord? decision }
  | _ => none

/-- A record as a tree. -/
def ReviewRecord.encode (record : ReviewRecord) : Value :=
  .record
    [("root", .str record.root), ("against", .str record.against), ("base", .str record.base),
      ("hunks", .list (record.hunks.toList.map (·.encode))),
      ("olds", .list (record.olds.toList.map .nat)), ("scope", record.scope.encode),
      ("head", .str record.head)]

/-- The record a tree is (`ReviewRecord.encode`), if it is one. -/
def ReviewRecord.decode? : Value → Option ReviewRecord
  |
  .record
      [("root", .str root), ("against", .str against), ("base", .str base), ("hunks", .list hunks),
        ("olds", .list olds), ("scope", scope), ("head", .str head)] =>
    do
    let hunks ← hunks.toArray.mapM ReviewHunk.decode?
    let olds ←
      olds.toArray.mapM fun
          | .nat index => some index
          | _ => none
    return { root, against, base, hunks, olds, scope := ← ReviewScope.decode? scope, head }
  | _ => none

/-- The hunks of `record` kept, reverted and not examined, by `entries`
("The record", in the module docs). -/
def Review.counts (record : ReviewRecord) (entries : Array Buffer.ExcerptEntry) : Nat × Nat × Nat :=
  ((record.hunks.filter (·.decision == .kept)).size,
    (record.hunks.filter (·.decision == .reverted)).size,
    (record.hunks.filter (!·.examined entries)).size)

/-- What the status line says of `record` (`Review.counts`). -/
def Review.statusText (record : ReviewRecord) (entries : Array Buffer.ExcerptEntry) : String :=
  let (kept, reverted, unexamined) := Review.counts record entries
  s!"{kept} kept · {reverted} reverted · {unexamined} not examined"

/-- The index of the hunk of `record` at `offset` of the review text whose
list is `placed` ("The record", in the module docs). -/
def Review.hunkAt (placed : Array Excerpt.Placed) (record : ReviewRecord) (offset : Nat) :
    Option Nat := do
  let excerpt ← placed.findIdx? fun excerpt => excerpt.start ≤ offset && offset ≤ excerpt.stop
  record.hunks.findIdx? fun hunk => hunk.old? == some excerpt || hunk.new? == some excerpt

end Editor.VersionControl
