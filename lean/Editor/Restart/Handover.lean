import Editor.Restart.Launch

/-!
# The hand-over record, and the plan of a restart

What a restart hands the next run: the record `<state>/session/handover`,
its text (`Handover.encode`), the executables it tries in order
(`candidates`), and what this run execs to start them (`Plan.invocation`).

## The record

The record is text, one field per line, each ending in a newline:

```text
leanmacs-handover 1
session <the index the next run restores>
shipped <the shipped default executable>
candidate <path>        (repeated, in the order they are tried)
argument <arg>          (repeated: the editor's own arguments)
```

A value is the rest of its line, with `\` written `\\` and a newline
written `\n`. The editor writes it once, through a snapshot save like the
index's (`restart-save`, `Editor/Restore/Restart.lean`); only the launcher
and its watcher read it or rewrite it, adding `failed <path>` lines
(`crates/editor-launch/src/handover.rs`). The editor reads back only the
candidates of a record the launcher gave up on (`handover.failed`,
`failedCandidates`), for the restore's report.

Kept compatible by one checked-in fixture, `tests/launch/handover-v1`:
the Rust decoder reads it and Lean's encoder must reproduce it byte for
byte (`ModelTest.restartHandoverChecks`).

## The candidates

A restart tries the executable it names (`into`, phase 8's new build),
then the running one, then the shipped default, each once
(`candidates`). With a launcher (`Launch.launchedBy`) the restart execs
`<launcher> --handover <record>`, and the launcher starts the first that
is not marked failed, with a watcher for the fallback. With none it execs
the first candidate itself, with `--restore` and `--handed-over`, and
there is no fallback (`Plan.invocation`).

## The exec

Both hosts, the headless mode's `main` and the window mode's `host`, exec a
plan the same way, once they have shut down: through `Plan.exec`, handed
the exec their collaborators hold (`Headless.Collaborators.replace`;
`Restart.real` for the executable, a fake in a test, and `noExec` by
default). An exec that succeeds never returns. One that fails is said
(`couldNotStart`) and the host exits 1; the session it wrote is not ended,
so the next start restores it.

## Where an addition goes

| Addition | Where |
|---|---|
| A new field of the record | A field of `Handover`, its line in `Handover.encode`, the Rust decoder and encoder (`crates/editor-launch/src/handover.rs`) and the fixture `tests/launch/handover-v1`, which both read; a field an older launcher must not skip raises the version on both sides |
| Another fact a restart in flight keeps | A field of `Handing` |

It imports only `Editor.Restart.Launch`, a leaf, so the state, the session's
reconciler (`Restore.Kept`) and the outbox can name its types.

Pinned by `ModelTest.restartHandoverChecks`.
-/

namespace Editor.Restart

/-- The record's format. -/
def version : Nat :=
  1

/-- What a restart hands the next run. -/
structure Handover where
  /-- The session index the next run restores. -/
  session : System.FilePath
  /-- The shipped default executable. -/
  shipped : System.FilePath
  /-- The executables to try, in order. -/
  candidates : Array System.FilePath := #[]
  /-- The editor's own arguments the next run is started with. -/
  arguments : List String := []
  deriving DecidableEq, Repr, Inhabited

/-- `value` as a field's value: `\` written `\\` and a newline `\n`. -/
def escape (value : String) : String :=
  value.foldl
    (fun out c =>
      if c == '\\' then out ++ "\\\\" else if c == '\n' then out ++ "\\n" else out.push c)
    ""

/-- The record's text ("The record", in the module docs). -/
def Handover.encode (handover : Handover) : String :=
  let line (key value : String) : String := s!"{key} {escape value}\n"
  s!"leanmacs-handover {version}\n" ++ line "session" handover.session.toString ++
    line "shipped" handover.shipped.toString ++
    (handover.candidates.foldl (fun out c => out ++ line "candidate" c.toString) "") ++
    handover.arguments.foldl (fun out a => out ++ line "argument" a) ""

/-- A field's value read back: `\\` as `\` and `\n` as a newline; any
other character, a stray `\` among them, as it is. -/
def unescape (field : String) : String :=
  (field.foldl
      (fun (out, escaping) c =>
        if escaping then (out.push (if c == 'n' then '\n' else c), false)
        else if c == '\\' then (out, true) else (out.push c, false))
      ("", false)).1

/-- The candidates a record's text names, in order: what the restore's
report says of a record the launcher gave up on (`handover.failed`). -/
def failedCandidates (text : String) : Array String :=
  ((text.splitOn "\n").filterMap fun line =>
      (line.dropPrefix? "candidate ").map fun rest => unescape rest.toString).toArray

/-- The executables a restart tries, in order, each once: `into` when one is
named, the running one and the shipped default. -/
def candidates (launch : Launch) (into : Option System.FilePath) : Array System.FilePath :=
  (into.toArray ++ launch.running.toArray ++ launch.shipped.toArray).foldl
    (fun found path => if found.contains path then found else found.push path) #[]

/-- A program and its arguments, as this run execs them. -/
structure Invocation where
  /-- The program: a path. -/
  program : System.FilePath
  /-- Its arguments, without the program. -/
  arguments : Array String := #[]
  deriving DecidableEq, Repr, Inhabited

/-- A restart's plan: where its record goes, what it holds, and the
launcher that started this run, if one did. -/
structure Plan where
  /-- The record's path, `<state>/session/handover`. -/
  record : System.FilePath
  /-- What the record holds. -/
  handover : Handover
  /-- The launcher to exec, if this run was launched by one. -/
  launcher : Option System.FilePath := none
  deriving DecidableEq, Repr, Inhabited

/-- What this run execs to hand over ("The candidates", in the module docs):
`<launcher> --handover <record>` with a launcher; with none, the first
candidate with `--restore <session> --handed-over <record>` and the
arguments. -/
def Plan.invocation (plan : Plan) : Invocation :=
  match plan.launcher with
  | some launcher => { program := launcher, arguments := #["--handover", plan.record.toString] }
  | none =>
    { program := plan.handover.candidates[0]?.getD plan.handover.shipped
      arguments :=
        #["--restore", plan.handover.session.toString, "--handed-over", plan.record.toString] ++
          plan.handover.arguments.toArray }

/-- The exec of a host that has none (`Headless.Collaborators.replace`'s
default): it refuses every invocation, saying so. -/
def noExec (_ : Invocation) : IO String :=
  pure "no exec in this host"

/-- What a host says when the restart's exec of `program` failed, for
`reason` ("The exec", in the module docs). -/
def couldNotStart (program : System.FilePath) (reason : String) : String :=
  s!"editor: the restart could not start {program}: {reason}; the session is kept and the next start restores it"

/-- What a host does with `plan` once it has shut down ("The exec", in the
module docs): flushes stdout and stderr, so nothing said is lost to the
exec, and execs `plan.invocation` through `replace`, once. `replace`
answers only when the exec failed, with the reason: that is said with
`say` (`couldNotStart`), and the answer is 1, the status the host exits
with. -/
def Plan.exec (plan : Plan) (replace : Invocation → IO String) (say : String → IO Unit) :
    IO UInt32 := do
  (← IO.getStdout).flush
  (← IO.getStderr).flush
  let invocation := plan.invocation
  let reason ← replace invocation
  say (couldNotStart invocation.program reason)
  return 1

/-- A restart in flight: from the probe's success until the exec, or until
the hand-over is abandoned (`Kept.handing`). -/
structure Handing where
  /-- The plan. -/
  plan : Plan
  /-- Whether the save of the index and the record has started. -/
  saving : Bool := false
  deriving DecidableEq, Repr, Inhabited

/-- What the echo area says while a hand-over is in flight, and in the last
frame drawn: with no launcher, that there is no fallback. -/
def handingLine (launched : Bool) : String :=
  "restart: handing the session over; the window closes and reopens" ++
    if launched then "" else " (no launcher, so no fallback)"

end Editor.Restart
