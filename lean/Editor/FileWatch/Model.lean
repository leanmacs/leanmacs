import Editor.FileWatch
import Editor.Process

/-!
# The pure model of what a job's watches see

The watches a job's requests start, and what changes on disk while they
watch, as a value. `FileWatchModel.handle` answers each watch request
(`Editor/FileWatch.lean`) as a pure function, with no file, no platform and
no library, so the logic above the job port is tested by `lake test` alone.
The job port's model hands its watch requests to it (`JobModel.fileWatches`,
`Editor/Job/Model.lean`), and the fake of the job runner's watch service is
this model behind a reference (`Editor/Job/Fake.lean`).

Nothing in a job's world changes the disk but the commands the job runs. So
the model holds, for each command a test expects, what it changes
(`effects`): the job model touches the watches with those changes when a run
of that command ends.

## How it answers

- **A start is refused in this order**: a path that is not absolute, or has
  a `..` component, as `notAbsolute`; a bound of 0, as `failed`; a
  directory, or a file's directory, not among `directories`, as `notFound`.
  None of them starts a watch.
- **A change is routed** as the library's service routes a notice: a file
  watch keeps its file's path; a watch of a directory's entries keeps the
  directory and what is directly inside it; a recursive one everything under
  it.
- **It is recorded** by the library's rule (`editor_watch::batch`): one
  change a path, with every kind added, in the order of each path's first
  change; the first change after a delivery opens the next; a change of a
  new path past the bound collapses the delivery to one change, `missed`, of
  the watch's own path, until it is taken.
- **A `next` with something recorded** answers it, at the instant the
  window has passed since the first change, or now if that is later, and
  moves the clock there.
- **A `next` with nothing recorded** can never be answered: the job is the
  only thing that changes the model's disk, and it is waiting. It is the
  cancel if one is due, and moves the clock there; otherwise it fails, as
  the process model's read that nothing can answer does.

The contract (`JobContract.fileWatchProperties`, `Editor/Job/Contract.lean`)
is what says the model, the fake and the library agree; the exact sets of
kinds, the window and the bound are checked against the model alone
(`ModelTest.fileWatchModelChecks`).
-/

namespace Editor

/-- Two replies of a `next` are equal when they are the same case with equal
contents. `Except` derives no equality. -/
instance : DecidableEq (Except FileWatchError (Array FileWatch.Change))
  | .ok a, .ok b =>
    if h : a = b then isTrue (congrArg Except.ok h) else isFalse fun e => h (Except.ok.inj e)
  | .error a, .error b =>
    if h : a = b then isTrue (congrArg Except.error h) else isFalse fun e => h (Except.error.inj e)
  | .ok _, .error _ => isFalse fun e => by cases e
  | .error _, .ok _ => isFalse fun e => by cases e

/-- A watch of the model's. -/
structure FileWatchModel.Watch where
  /-- Its id. -/
  id : Nat
  /-- What it is on. -/
  target : FileWatch.Target
  /-- How its changes are coalesced. -/
  coalescing : FileWatch.Coalescing
  /-- What it recorded and has not delivered, in the order of each path's
  first change. -/
  changes : Array FileWatch.Change := #[]
  /-- When its first change since the last delivery came, if one has. -/
  opened : Option Nat := none
  /-- Whether what it recorded has collapsed to `missed` of its own path. -/
  collapsed : Bool := false
  deriving DecidableEq

/-- The model of what a job's watches see. -/
structure FileWatchModel where
  /-- The directories there are. -/
  directories : Array System.FilePath := #[]
  /-- Every watch started and not ended, oldest first. -/
  watches : Array FileWatchModel.Watch := #[]
  /-- The id the next watch is given. -/
  next : Nat := 1
  /-- What each command a test expects changes on disk: each path and the
  kind of its change, in order. -/
  effects : Array (Process.Command × Array (System.FilePath × FileWatch.Kind)) := #[]
  /-- Every watch ended with its job, oldest first. -/
  ended : Array Nat := #[]
  deriving DecidableEq

namespace FileWatchModel

/-- What a run of `command` changes on disk: nothing for a command with no
effects. -/
def effectsOf (model : FileWatchModel) (command : Process.Command) :
    Array (System.FilePath × FileWatch.Kind) :=
  ((model.effects.find? (·.1 == command)).map (·.2)).getD #[]

/-- Whether `path` is `directory` or under it, by components. -/
def under (path directory : System.FilePath) : Bool :=
  let parts := directory.components
  path.components.take parts.length == parts

/-- Whether a watch on `target` keeps a change of `path`: the library's
router (`editor_watch::service`). -/
def keeps (target : FileWatch.Target) (path : System.FilePath) : Bool :=
  match target with
  | .file file => path == file
  | .directory directory false => path == directory || path.parent == some directory
  | .directory directory true => under path directory

namespace Watch

/-- `watch` with the change of `path` of `kind`, made at `now`, recorded by
the library's rule (`editor_watch::batch`). -/
def record (watch : Watch) (path : System.FilePath) (kind : FileWatch.Kind) (now : Nat) : Watch :=
  let watch := { watch with opened := some (watch.opened.getD now) }
  let collapse (watch : Watch) : Watch :=
    { watch with
      changes := #[{ path := watch.target.path, kinds := FileWatch.Kinds.add {} .missed }]
      collapsed := true }
  if watch.collapsed then watch
  else
    if kind == .missed then collapse watch
    else
      match watch.changes.findIdx? (·.path == path) with
      | some index =>
        { watch with
          changes :=
            watch.changes.modify index fun change =>
              { change with kinds := change.kinds.add kind } }
      | none =>
        if watch.changes.size < watch.coalescing.bound then
          { watch with
            changes := watch.changes.push { path, kinds := FileWatch.Kinds.add {} kind } }
        else collapse watch

end Watch

/-- Records `changes`, made at `now`, in each watch they are for. -/
def touch (model : FileWatchModel) (changes : Array (System.FilePath × FileWatch.Kind))
    (now : Nat) : FileWatchModel :=
  { model with
    watches :=
      model.watches.map fun watch =>
        changes.foldl (init := watch) fun watch (path, kind) =>
          if keeps watch.target path then watch.record path kind now else watch }

/-- Why `path` may not be watched at all, if it may not: the library's
`refusal_before_watch`. -/
def refusal (path : System.FilePath) : Option FileWatchError :=
  if !path.isAbsolute then some (.notAbsolute s!"cannot watch {path}: the path is not absolute")
  else
    if path.components.contains ".." then
      some (.notAbsolute s!"cannot watch {path}: the path has a `..` component")
    else none

/-- The directory a watch on `target` needs there: a file's own, or the
directory's. -/
def directoryOf : FileWatch.Target → Option System.FilePath
  | .file file => file.parent
  | .directory directory _ => some directory

/-- The model's answer to `request` made at `now` by a job cancelled at
`cancelAt`, the model after it, and the clock after it. -/
def handle (model : FileWatchModel) (now : Nat) (cancelAt : Option Nat) :
    (request : FileWatchRequest) → request.Reply × FileWatchModel × Nat
  | .start target coalescing =>
    match refusal target.path with
    | some error => (.error error, model, now)
    | none =>
      if coalescing.bound == 0 then
        (.error (.failed s!"cannot watch {target.path}: a bound of 0 holds nothing"), model, now)
      else
        match directoryOf target with
        | some directory =>
          if model.directories.contains directory then
            (.ok ⟨model.next⟩,
              { model with
                watches := model.watches.push { id := model.next, target, coalescing }
                next := model.next + 1 },
              now)
          else
            (.error (.notFound s!"cannot watch {target.path}: {directory} is not there"), model,
              now)
        | none =>
          (.error (.notFound s!"cannot watch {target.path}: it has no directory"), model, now)
  | .next watch =>
    match model.watches.find? (·.id == watch.number) with
    | none => (.error .noSuchWatch, model, now)
    | some found =>
      match found.opened with
      | some opened =>
        let due := max now (opened + found.coalescing.window)
        let taken :=
          { found with
            changes := #[], opened := none, collapsed := false }
        (.ok found.changes,
          { model with
            watches := model.watches.map fun w => if w.id == found.id then taken else w },
          due)
      | none =>
        -- Nothing can ever answer this read: only a cancel ends it.
        match cancelAt with
        | some instant => (.error (.failed "the job was cancelled"), model, max now instant)
        | none =>
          (.error (.failed "the model's watch waits for a change nothing makes"), model, now)

/-- Ends every watch, as the runner does when their job ends: each is
recorded as ended, and forgotten. -/
def endAll (model : FileWatchModel) : FileWatchModel :=
  { model with
    watches := #[], ended := model.ended ++ model.watches.map (·.id) }

end FileWatchModel

end Editor
