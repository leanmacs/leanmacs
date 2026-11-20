/-!
# How this run was launched

The launch flags the app's launcher gives an editor first on its command
line (`crates/editor-launch/src/launch.rs`, `flags`), read into a
`Restart.Launch` before the executable's mode is chosen
(`Editor/Executable.lean`), and what a host adds to it: the running
executable and the arguments a restart hands on.

- `--launched-by <launcher>`: the launcher that started this run, which a
  restart execs again (`Plan.invocation`, `Editor/Restart/Handover.lean`).
- `--shipped <exe>`: the shipped default executable, the last fallback.
- `--restore <index>`: the session index the restart handed over, which the
  restore reads in place of choosing one (`Editor/Restore/Run.lean`).
- `--handed-over <record>`: the hand-over record, which this run removes
  once it has restored the session and written its own index: the
  hand-shake (`Editor/Restore.lean`).
- `--failed <exe>` (repeated): an executable that ended before it restored
  the session, which the restore's summary names.

`strip` takes them from the front of the command line, in any order, and
stops at the first other word, so a flag after it is the mode's. A flag
with no value is left in place, and the mode refuses it as an option it
does not know.

It imports nothing: a leaf, so the editor state (`EditorState.launch`) and
the executable's dispatch can both name it.

Pinned by `ModelTest.restartLaunchChecks`.
-/

namespace Editor.Restart

/-- What this run was launched with, and what a restart hands on. -/
structure Launch where
  /-- The launcher that started this run (`--launched-by`); none for a run
  started directly. -/
  launchedBy : Option System.FilePath := none
  /-- The shipped default executable (`--shipped`). -/
  shipped : Option System.FilePath := none
  /-- The session index a restart handed over (`--restore`). -/
  restore : Option System.FilePath := none
  /-- The hand-over record to remove at the hand-shake (`--handed-over`). -/
  handedOver : Option System.FilePath := none
  /-- The executables that ended before they restored the session
  (`--failed`), in order. -/
  failed : Array System.FilePath := #[]
  /-- The executable this run is, which the edge reads (`IO.appPath`). -/
  running : Option System.FilePath := none
  /-- The editor's own arguments a restart hands on, after the launch
  flags: the host's command line, as each host makes it. -/
  arguments : List String := []
  deriving DecidableEq, Repr, Inhabited

/-- The launch flags taken from the front of `arguments`, and the rest. -/
def Launch.strip (arguments : List String) : Launch × List String :=
  go {} arguments
where
  /-- Takes the flags from the front, into `launch`. -/
  go (launch : Launch) : List String → Launch × List String
    | "--launched-by" :: value :: rest => go { launch with launchedBy := some value } rest
    | "--shipped" :: value :: rest => go { launch with shipped := some value } rest
    | "--restore" :: value :: rest => go { launch with restore := some value } rest
    | "--handed-over" :: value :: rest => go { launch with handedOver := some value } rest
    | "--failed" :: value :: rest => go { launch with failed := launch.failed.push value } rest
    | rest => (launch, rest)

/-- The hand-over record a run started with `launch` removes as it starts,
before anything else: one handed over (`--handed-over`) to a run with no
state directory, which has no restore to finish, so its hand-shake is its
start. A run with a state directory removes it at its restore's hand-shake
(`Editor/Restore.lean`). A record handed with no `--restore` is the
launcher's cold start under watch (`crates/editor-launch/src/launch.rs`):
the hand-shake tells its watcher this run started. -/
def Launch.removedAtStart (launch : Launch) (stateDirectory : Bool) : Option System.FilePath :=
  if stateDirectory then none else launch.handedOver

/-- The record the probe removes once `main` is reached: the one it was
handed, so a cold start under watch that probes (`leanmacs … --probe`)
ends with no record left for its watcher to fall back on. -/
def Launch.probeRemoves (launch : Launch) : Option System.FilePath :=
  launch.handedOver

/-- What `editor --probe` prints for a run launched with `launch`, which is
the executable at `executable` and sees `bundle` as CoreFoundation's main
bundle (its path and identifier, or none): `probe: ok`, the launcher,
the bundle, and the executable, so a check can see which executable a
launcher chose. -/
def probeLines (launch : Launch) (executable : String) (bundle : Option (String × Option String)) :
    List String :=
  let seen :=
    match bundle with
    | some (path, identifier) => s!"bundle {path} identifier {identifier.getD "none"}"
    | none => "bundle none"
  ["probe: ok", s!"launched-by {(launch.launchedBy.map (·.toString)).getD "none"}", seen,
    s!"executable {executable}"]

end Editor.Restart
