import Editor.Job.Contract
import Editor.UndoTree.Cases

/-!
# Cases that cross the text port and the job port

What a command, a job and the job's command do together, as one list of
cases: a file a job loads becomes a text, a snapshot a command took is saved
by a job, and a save that reports late marks the undo tree's state it wrote.
Each port has its own contract (`Editor/Text/Contract.lean`,
`Editor/Job/Contract.lean`); these are about what is handed from one to the
other.

A case is the stages of one such exchange, as the runtime plays them:

1. the files there are to start with, in a directory the player makes;
2. `first`, a command, run from an empty store;
3. `job`, a job, given the directory and what `first` returned. A snapshot
   `first` took is read by the job by its id;
4. `handler`, the job's command, given what `first` returned and what the
   job returned, in a run that is handed what the job held;
5. `last`, a command like any other, run once the job has been settled, so
   in a run that is handed nothing, which says whether the case held;
6. every file that must be in the directory afterwards.

A job finishes with a command of no result, as every job does (`Work`,
`Editor/Job.lean`), so what `handler` has to say reaches `last` through the
text store: `first` makes a text for it, `handler` writes into it and `last`
reads it (`held`, `notHeld`). An id the store gives next is named as the
port's rules give it: the index after the last one `first` got.

Whoever plays the list hands the values across. `model-test` plays it on
the two models: the job's model starts with the text model's snapshots as
the published ones, and the job's command runs against the text model with
what the job's model held as what arrived. `contract-test` plays it on the
real binding and the library's file service, on real files, with the job
run by the runner and its command by `Job.finishWith`, as the loop runs
it.

This module imports the two contracts, for their helpers, and the cases of
the undo tree, for theirs. It imports no model and no real binding. The list
is plain data, programs that have not run.
-/

namespace Editor.FileCases

open TextContract (refusedWith)
open JobContract (loaded saved saveRefusedAs rawFile otherFile roomy)
open UndoTreeCases (group reads)

/-- One exchange between a command, a job and the job's command. -/
structure Case where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- The files there are to start with, each a name in the directory and
  its bytes. -/
  files : Array (String × ByteArray)
  /-- What `first` returns, for the stages after it. -/
  {α : Type}
  /-- What the job returns, for its command. -/
  {β : Type}
  /-- The command that runs first, from an empty store. -/
  first : EditorM α
  /-- The job, given the directory, an absolute path, and what `first`
  returned. -/
  job : System.FilePath → α → JobM β
  /-- The job's command, given what `first` returned and what the job
  returned. Its run is handed what the job held. -/
  handler : α → β → EditorM Unit
  /-- The command that runs once the job has been settled, given what
  `first` returned; `true` when the case held. Its run is handed nothing. -/
  last : α → EditorM Bool
  /-- Every file that must be in the directory afterwards, each a name and
  its bytes, in any order. -/
  after : Array (String × ByteArray)

/-- What a job's command writes into the text `first` made for it when what
it saw is what the case expects. -/
def held : String :=
  "held"

/-- What a job's command writes when what it saw is not what the case
expects. -/
def notHeld : String :=
  "not held"

/-- Writes into `verdict`, an empty text, whether `ok`. -/
def report (verdict : TextId) (ok : Bool) : EditorM Unit :=
  verdict.insert 0 (if ok then held else notHeld)

/-- A file's bytes: "é", "😀", the byte `FF`, a carriage return and a line
feed. Nine bytes. -/
def noteBytes : ByteArray :=
  ⟨#[0xC3, 0xA9, 0xF0, 0x9F, 0x98, 0x80, 0xFF, 0x0D, 0x0A]⟩

/-- The text `noteBytes` loads as, written out by hand: the byte `FF` is its
escape. Twelve bytes, in two rows. -/
def noteText : String :=
  ("é😀".push (Char.ofNat 0x10DCFF)) ++ "\r\n"

/-- A text with an escape: "héllo", the escape of the byte `FF`, and a line
feed. Saved, it is the eight bytes `savedBytes`. -/
def escapedText : String :=
  ("héllo".push (Char.ofNat 0x10DCFF)).push '\n'

/-- The bytes `escapedText` is saved as, written out by hand: the escape is
its one byte. -/
def savedBytes : ByteArray :=
  ⟨#[0x68, 0xC3, 0xA9, 0x6C, 0x6C, 0x6F, 0xFF, 0x0A]⟩

/-- The text `JobContract.rawFile` loads as, written out by hand: the bytes
`E9` and `FF`, and each of the four bytes of the reserved code point, are
their escapes. -/
def rawText : String :=
  "a\r\nb\n" ++
    [0xE9, 0xFF, 0xF4, 0x8D, 0xB2, 0x80].foldl
      (fun text byte => text.push (Char.ofNat (0x10DC00 + byte))) "" ++
    "😀\rz"

/-- What the undo-tree cases start from: a text holding `escapedText` with a
tree over it and one closed group that added " wörld"; the tree's state then
and a snapshot of the text then, which is what a save writes; and an empty
text for the job's command to report into. -/
structure Edited where
  /-- The tree, after its one group. -/
  tree : UndoTree
  /-- The state the text was in when the snapshot was taken. -/
  state : UndoTree.State
  /-- The snapshot a save writes. -/
  taken : SnapshotId
  /-- Where the job's command reports. -/
  verdict : TextId

/-- Makes what `Edited` describes. The text is modified: its tree was saved
at its root, before the group. -/
def edited : EditorM Edited := do
  let text ← createText escapedText
  let tree ← UndoTree.over text
  let tree ← group tree " wörld"
  let taken ← text.snapshot
  let verdict ← createText ""
  return { tree, state := tree.state, taken, verdict }

/-- The bytes a save of `edited`'s snapshot writes, written out by hand:
`savedBytes` and " wörld". -/
def editedBytes : ByteArray :=
  ⟨#[0x68, 0xC3, 0xA9, 0x6C, 0x6C, 0x6F, 0xFF, 0x0A, 0x20, 0x77, 0xC3, 0xB6, 0x72, 0x6C, 0x64]⟩

/-- The cases. -/
def cases : List Case :=
  [{  name :=
        "a file a job loads becomes a text: with a text and a snapshot of the store already at index 0 holding something else, the job's command adopts what was loaded and copies it, and the next command reads the file's text, with its escape, its length and its rows, in a new text at revision 0, with no snapshot left of it",
      files := #[("note.txt", noteBytes)]
      first := do
        let other ← createText "other"
        return (other, ← other.snapshot)
      job := fun root _ => do
        return (← loaded (root / "note.txt")).snapshot
      handler := fun _ file => discard file.toText
      last := fun (other, taken) => do
        -- The store's next text and its next snapshot, after `first`'s.
        let text : TextId := ⟨other.index + 1⟩
        let adopted : SnapshotId := ⟨taken.index + 1⟩
        let released ← refusedWith .noSuchSnapshot (discard adopted.read)
        return (← text.read) == noteText && (← text.byteLength) == 12 && (← text.rowCount) == 2 &&
            (← text.revision) == 0 &&
            released &&
            (← other.read) == "other" &&
            (← taken.read) == "other"
      after := #[("note.txt", noteBytes)] },
    { name :=
        "a snapshot a command took is saved by a job: the text has an escape and has moved on since the snapshot, and the file holds the snapshot's bytes, the escape as its one byte"
      files := #[]
      first := do
        let text ← createText escapedText
        let taken ← text.snapshot
        text.insert 0 "x"
        return (text, taken, ← createText "")
      job := fun root (_, taken, _) => do
        return (← saved (.snapshot taken) (root / "out.txt") .absent).size
      handler := fun (_, _, verdict) size => report verdict (size == 8)
      last := fun (text, taken, verdict) => do
        return (← verdict.read) == held && (← taken.read) == escapedText &&
            (← text.read) == "x" ++ escapedText
      after := #[("out.txt", savedBytes)] },
    { name :=
        "a save that reports late marks the state it wrote: the command keeps the tree's state beside the snapshot, the job's command makes a further edit, as if the user had typed while the save ran, and marks the kept state saved: the text is then modified, and one undo, back to the kept state, makes it unmodified"
      files := #[]
      first := edited
      job := fun root start => File.save (.snapshot start.taken) (root / "out.txt") .absent
      handler := fun start reply => do
        let tree ← group start.tree "😀"
        match reply with
        | .ok stamp =>
          let tree := tree.markSaved start.state
          let modified := tree.isModified
          let some undone ← tree.undo | report start.verdict false
          report start.verdict
              (stamp.size == 15 && modified && !undone.tree.isModified &&
                undone.tree.state == start.state)
        | .error _ =>
          report start.verdict false
      last := fun start => do
        return (← start.verdict.read) == held && (← start.tree.text.read) == escapedText ++ " wörld"
      after := #[("out.txt", editedBytes)] },
    { name :=
        "a save that is refused marks nothing: the file changed, the save is refused as changed with what is there, and after the further edit the text is modified, and still modified one undo back at the state the save would have written"
      files := #[("out.txt", otherFile)]
      first := edited
      job := fun root start => File.save (.snapshot start.taken) (root / "out.txt") .absent
      handler := fun start reply => do
        let tree ← group start.tree "😀"
        match reply with
        | .error (.changed (some found)) =>
          let modified := tree.isModified
          let some undone ← tree.undo | report start.verdict false
          report start.verdict
              (found.size == 12 && modified && undone.tree.isModified &&
                undone.tree.state == start.state)
        | _ =>
          report start.verdict false
      last := fun start => do
        return (← start.verdict.read) == held
      after := #[("out.txt", otherFile)] },
    { name :=
        "a snapshot a command released is refused by the job as naming no snapshot, and no file is written"
      files := #[]
      first := do
        let text ← createText escapedText
        let taken ← text.snapshot
        taken.release
        return (taken, ← createText "")
      job := fun root (taken, _) =>
        saveRefusedAs .noSuchSnapshot (.snapshot taken) (root / "out.txt") .absent
      handler := fun (_, verdict) refused => report verdict refused
      last := fun (_, verdict) => do
        return (← verdict.read) == held
      after := #[] },
    { name :=
        "what a job held is gone once its command has run, and what the command adopted is not: the job loads two files and its command adopts the first; the next command reads the adopted snapshot, and is refused when it adopts either of the job's ids"
      files := #[("a.txt", rawFile), ("b.txt", otherFile)]
      first := do
        let other ← createText "other"
        return (← other.snapshot, ← createText "")
      job := fun root _ => do
        let first ← loaded (root / "a.txt")
        let second ← loaded (root / "b.txt")
        return (first.snapshot, second.snapshot)
      -- The job's ids reach the next command as numbers in a text.
      handler := fun (_, mail) (first, second) => do
        discard first.adopt
        mail.insert 0 s!"{first.number},{second.number}"
      last := fun (taken, mail) => do
        let [first, second] := ((← mail.read).splitOn ",").filterMap (·.toNat?) | return false
        let adopted : SnapshotId := ⟨taken.index + 1⟩
        let gone ← refusedWith .noSuchSnapshot (discard (JobSnapshotId.mk first).adopt)
        let goneToo ← refusedWith .noSuchSnapshot (discard (JobSnapshotId.mk second).adopt)
        return first != second && gone && goneToo && (← adopted.read) == rawText &&
            (← adopted.byteLength) == 35
      after := #[("a.txt", rawFile), ("b.txt", otherFile)] }]

end Editor.FileCases
