import Editor.Process

/-!
# The pure model of the processes a job runs

The processes a job's requests start, as a value: a script for each command
a test expects, saying what the command answers and how long it takes, and
a record of what was started and what was killed. `ProcessModel.handle`
answers each process request (`Editor/Process.lean`) as a pure function,
with no process and no library, so the logic above the job port is tested
by `lake test` alone. The job port's model hands its process requests to it
(`JobModel.processes`, `Editor/Job/Model.lean`), and the fake of the job
runner's process service is this model behind a reference
(`Editor/Job/Fake.lean`).

## How it answers

- **A run is refused in this order**: a directory that is not absolute; a
  program that names a directory and is not absolute; a command with no
  script, as `notFound`, as a program that is not there would be. None of
  them starts anything.
- **A scripted run** is recorded as started, and moves the job clock on by
  the script's `takes`, in milliseconds: so a job model whose cancellation
  falls inside the run sees it there, as it sees one inside a wait. Then the
  run is recorded as killed, which is what the library does to a cancelled
  job's child.
- **A stream past the limit** answers `outputTooLarge`, standard output
  looked at first, in place of the script's reply.

The contract (`JobContract.processProperties`, `Editor/Job/Contract.lean`)
is what says the model, the fake and the library agree: each property
carries the scripts of its commands, and the library's run of the same
property is what shows them true. A clause added to `ProcessModel.handle`
needs its property there.
-/

namespace Editor

/-- Two replies of a run are equal when they are the same case with equal
contents. `Except` derives no equality, and a script holds one. -/
instance : DecidableEq (Except ProcessError Process.Ran)
  | .ok a, .ok b =>
    if h : a = b then isTrue (congrArg Except.ok h) else isFalse fun e => h (Except.ok.inj e)
  | .error a, .error b =>
    if h : a = b then isTrue (congrArg Except.error h)
    else isFalse fun e => h (Except.error.inj e)
  | .ok _, .error _ => isFalse fun e => by cases e
  | .error _, .ok _ => isFalse fun e => by cases e

/-- What a scripted command does. -/
structure Process.Script where
  /-- The command. -/
  command : Process.Command
  /-- What a run of it answers, within any limit. -/
  reply : Except ProcessError Process.Ran
  /-- How long a run of it takes, in milliseconds on the job clock. -/
  takes : Nat := 0
  deriving DecidableEq

/-- The model of the processes a job runs. -/
structure ProcessModel where
  /-- What each command a test expects does. -/
  scripts : Array Process.Script := #[]
  /-- Every command started, oldest first. -/
  started : Array Process.Command := #[]
  /-- Every command killed because its job was cancelled while it ran,
  oldest first. -/
  killed : Array Process.Command := #[]
  deriving DecidableEq

namespace ProcessModel

/-- Whether `program` names a directory without being absolute. -/
def relativeProgram (program : String) : Bool :=
  program.contains '/' && !program.startsWith "/"

/-- What a run of `command` under `limit` answers when the command is
scripted to answer `reply`: a stream past the limit, standard output first,
is too large. -/
def limited (limit : Nat) : Except ProcessError Process.Ran → Except ProcessError Process.Ran
  | .ok ran =>
    if ran.stdout.size > limit then .error (.outputTooLarge .out limit)
    else if ran.stderr.size > limit then .error (.outputTooLarge .err limit)
    else .ok ran
  | .error error => .error error

/-- The model's answer to `request` made at `now` on the job clock, by a job
cancelled at `cancelAt` if it ever is: the reply, the model after it, and
the clock after it. -/
def handle (model : ProcessModel) (now : Nat) (cancelAt : Option Nat) :
    (request : ProcessRequest) → request.Reply × ProcessModel × Nat
  | .run command limit =>
    if !command.directory.isAbsolute then (.error .relativeDirectory, model, now)
    else if relativeProgram command.program then (.error .relativeProgram, model, now)
    else
      match model.scripts.find? (·.command == command) with
      | none =>
        (.error
            (.notFound
              s!"cannot start `{command.program}` in {command.directory}: the model has no script for it"),
          model, now)
      | some script =>
        let after := now + script.takes
        let started := { model with started := model.started.push command }
        let killed := cancelAt.any fun instant => now < instant && instant ≤ after
        (limited limit script.reply,
          if killed then { started with killed := started.killed.push command } else started, after)

end ProcessModel

end Editor
