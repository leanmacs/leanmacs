import Editor.Api
import Editor.Job
import Editor.Process
import Editor.Restore

/-!
# `:restart`: the session handed to a new process

The `restore` package's restart (`packages/restore/`), over the
session's reconciler (`Editor/Restore.lean`) and the plan of
`Editor/Restart/Handover.lean`. `:restart` re-execs the running executable;
`:restart <exe>` and `Editor.restart (into := some exe)` exec another, as
packages phase 8's install does. Either way the editor ends with a new
process running, the session as it was.

- **The command `restart`** (ex name `restart`, taking an optional
  executable) refuses, each a line in the echo area: with no state
  directory (`restart: no state directory, so the session cannot be kept`),
  while the restore has not finished (`Kept.run` is none), while a restart
  is in flight (`Kept.handing`), and for an executable that is not an
  absolute path. Otherwise it starts the job `restart-probe`, keyed
  `restart`, with the target: the executable named, or the running one
  (`Launch.running`).
- **The probe** (`restart-probe`) runs `<target> --probe` through the
  process service, from `/`, in the editor's own environment as the exec
  that follows does, for at most `probePatience` (10 s). It must
  exit 0 with the first line `probe: ok`: `--probe` returns once `main` is
  reached, so every module initialiser has run (`Editor/Main.lean`). That
  catches what fails before `main`: a bad link, a bad signature, a missing
  library, an `initialize` that throws. Otherwise the command says
  `restart: <target> did not start: <how it ended>; <its first line of
  standard error>; the editor keeps running`, and nothing is handed over.
- **Accepted**, the command sets `Kept.handing` with the plan: the record
  `<state>/session/handover`, what it holds (this run's index, the shipped
  executable, the candidates, `Restart.candidates`, and the host's
  arguments, `Launch.arguments`) and the launcher. It says the hand-over
  (`Restart.handingLine`). From then on the loop drops the user's input and
  the editor does not leave (`Editor/Loop.lean`, "A restart in flight").
- **The save** (`restart-save`), which the reconciler starts once no save
  is in flight, after this publish's journal orders: it makes
  `session/`, saves the index, not ended, over this run's
  `session-<run>.json`, then the record over `session/handover`, each an
  observed save of a snapshot. The file service works its one queue in
  order, so both follow every journal order handed before them. Its
  command hands the plan to the host (`Editor.handOver`), which ends its
  loop, shuts down and execs it. A save refused is said (`restart: the
  session could not be written: <why>; the editor keeps running`), the
  record removed and the hand-over given up: the journal carries on.
- **`restart-abandon`**, which a host runs with a reason when it will not
  exec the plan (a journal order failed since the hand-over began), says
  the reason and gives the hand-over up. It forgets every live journal, so
  the reconciler writes a new generation of each journalled buffer and
  removes the old ones: a record that failed may be missing from them.
- **The jobs** are registered restarted (`workJob … (restarted := true)`),
  so the index the hand-over writes does not count them as stopped by the
  restart.

## Where an addition goes

| Addition | Where |
|---|---|
| Another refusal of `:restart` | `restartCommand`, said as one line |
| Another check of the target before the hand-over | `probed`, beside the exit status and the first line |
| Another file the hand-over writes | `restartSaveWork`, after the index and before the record, whose save is the last |
| Another fact the next run is told | `Restart.Handover` and the record (`Editor/Restart/Handover.lean`, "Where an addition goes") |

Pinned by `ModelTest.restartChecks`, on the loop's driver over the models.
-/

namespace Editor.Restore

/-- How long the probe may run, in milliseconds of the job clock. -/
def probePatience : Nat :=
  10000

/-- How much of each of the probe's streams is read, in bytes. -/
def probeLimit : Nat :=
  65536

/-- Sets what the session's reconciler keeps (`StateRequest.setRestore`). -/
def keep (kept : Kept) : EditorM Unit :=
  EditorState.ask (.setRestore kept)

/-- What `:restart` says when it is refused for `why`. -/
def restartRefused (why : String) : String :=
  s!"{Editor.restartName}: {why}"

/-- The command `restart` ("`:restart`", in the module docs): its first
argument, when there is one and it is not blank, the executable to restart
into. -/
def restartCommand (call : Call) : EditorM Unit := do
  let state ← editorState
  let into : Option System.FilePath :=
    match call.arguments with
    | .str text :: _ =>
      let text := text.trimAscii.toString
      if text.isEmpty then none else some text
    | _ => none
  let some _ :=
    state.stateDirectory | message (restartRefused "no state directory, so the session cannot be kept")
  let some _ := state.restore.run | message (restartRefused "the session is still being restored")
  if state.restore.handing.isSome then
    message (restartRefused "a restart is already in flight")
    return
  if let some path := into then
    unless path.isAbsolute do
      message (restartRefused s!"{path} is not an absolute path")
      return
  let some target :=
    into <|> state.launch.running | message (restartRefused "the running executable is not known")
  let arguments := [.str target.toString, .str ((into.map (·.toString)).getD "")]
  if let .error refusal← startJob probeJob arguments (key := some Editor.restartName) then
    message (restartRefused refusal.describe)

/-- The first line of `bytes`, read as text. -/
def firstLine (bytes : ByteArray) : String :=
  ((String.fromUTF8? bytes).getD "" |>.splitOn "\n").head!.trimAscii.toString

/-- How the probe's run `ran` failed, or none when it passed: status 0 and
the first line `probe: ok`. -/
def probeFailure (ran : Process.Ran) : Option String :=
  let line := firstLine ran.stdout
  let how :=
    match ran.exit with
    | .code 0 =>
      if line == "probe: ok" then none else some s!"its first line was `{line}`, not `probe: ok`"
    | .code n => some s!"it exited with status {n}"
    | .signal n => some s!"the signal {n} ended it"
  how.map fun how =>
    let said := firstLine ran.stderr
    if said.isEmpty then how else s!"{how}; {said}"

/-- What the probe of `target` came to (`reply`): the hand-over planned and
begun when it passed, said and given up otherwise ("The probe", in the
module docs). `into` is the executable named, if one was. -/
def probed (target : System.FilePath) (into : Option System.FilePath)
    (reply : Except ProcessError Process.Ran) : EditorM Unit := do
  let failure :=
    match reply with
    | .error error => some error.describe
    | .ok ran => probeFailure ran
  if let some how := failure then
    message (restartRefused s!"{target} did not start: {how}; the editor keeps running")
    return
  let state ← editorState
  let kept := state.restore
  let (some directory, some run) := (state.stateDirectory, kept.run) | return
  if kept.handing.isSome then
    return
  let launch := state.launch
  let plan : Restart.Plan :=
    { record := recordPath directory
      handover :=
        { session := indexPath directory run
          shipped := (launch.shipped <|> launch.running).getD target
          candidates := Restart.candidates launch into
          arguments := launch.arguments }
      launcher := launch.launchedBy }
  keep { kept with handing := some { plan } }
  message (Restart.handingLine launch.launchedBy.isSome)

/-- The probe's command: `<target> --probe`, from `/`. -/
def probeCommand (target : System.FilePath) : Process.Command :=
  { program := target.toString, arguments := #["--probe"], directory := "/" }

/-- The job `restart-probe`: `<target> --probe` (`probeCommand`), run within
`probePatience`, and its command (`probed`). It runs in the editor's own
environment, as the exec that follows does, with no directory's lookup
(`Process.prepared`): the probe is of the start the restart makes. -/
def probeWork (arguments : List Argument) : Work := fun _ => do
  let .str target :: .str into :: _ :=
    arguments | throw s!"{probeJob}: its arguments are not a probe's"
  let reply ← Process.request (.runWithin (probeCommand target) probeLimit probePatience)
  return probed target (if into.isEmpty then none else some into) reply

/-- What the save of the session and the record came to: both snapshots
released, and the plan handed to the host, or the refusal said and the
hand-over given up ("The save", in the module docs). -/
def restartSaved (index record : Nat) (reply : Except String Unit) : EditorM Unit := do
  (SnapshotId.release ⟨index⟩ : TextM Unit)
  (SnapshotId.release ⟨record⟩ : TextM Unit)
  let kept := (← editorState).restore
  let some handing := kept.handing | return
  match reply with
  | .error why =>
    keep { kept with handing := none }
    message (restartRefused s!"the session could not be written: {why}; the editor keeps running")
  | .ok () =>
    Editor.handOver handing.plan

/-- The job `restart-save`: `session/` made, the index's snapshot saved over
this run's index and the record's over the record, in that order; the
record removed when a save is refused. Its command is `restartSaved`. -/
def restartSaveWork (arguments : List Argument) : Work := fun _ => do
  let .nat index :: .nat record :: .str session :: .str indexFile :: .str recordFile :: _ :=
    arguments | throw s!"{restartSaveJob}: its arguments are not a save's"
  let refused (path : String) (error : FileError) : JobM (EditorM Unit) := do
    discard <| File.remove recordFile
    return restartSaved index record (.error s!"{path}: {error.describe}")
  if let .error error← File.makeDirectory session then
    return ← refused session error
  if let .error error← File.save (.snapshot ⟨index⟩) indexFile .whatever then
    return ← refused indexFile error
  if let .error error← File.save (.snapshot ⟨record⟩) recordFile .whatever then
    return ← refused recordFile error
  return restartSaved index record (.ok ())

/-- `restart-abandon`: says its first argument, the reason, and gives the
hand-over up ("`restart-abandon`", in the module docs): every live journal
is forgotten, its files kept to remove once the new bases are asked for,
so each journalled buffer gets a new generation. -/
def abandonCommand (call : Call) : EditorM Unit := do
  let kept := (← editorState).restore
  let reason :=
    match call.arguments with
    | .str text :: _ => text
    | _ => restartRefused "the hand-over was given up"
  let some directory := (← editorState).stateDirectory | return
  let stale :=
    match kept.run with
    | some run =>
      kept.journals.flatMap fun (journal : Journal) =>
        #[basePath directory run journal.buffer journal.generation,
          logPath directory run journal.buffer journal.generation]
    | none => #[]
  keep
      { kept with
        handing := none, journals := #[], stale := kept.stale ++ stale, written := none }
  message reason

end Editor.Restore
