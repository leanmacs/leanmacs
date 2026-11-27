import Echo.Job
import Echo.Real
import Editor.Api
import Editor.Package
import Editor.Setup

/-!
# The packages of the Lake package `echo`

One, `echo`: two jobs that reach the package's service through the job
port (`Echo/Job.lean`), the commands that start them, and the service
itself, the Rust-backed binding as the runner's package service
(`Echo.Real.service`), which the program's edge hands the job runner
(`Package.services`, `Headless.shipped`).

- **`echo-say`** starts the job `echo-say`, which asks the service to say
  the command's first argument, `hello` when it has none, and says
  `echo: <text> <checksum>` in the echo area once the reply comes.
- **`echo-attach`** starts the job `echo-attach` under the key
  `echo-attach`: it opens `/bin/sh -c` `attachScript` as a streaming child
  with a bound of four mebibytes and its input piped, hands it to the
  crate, and says `echo-attach: ` and what the crate read once the crate
  has read it to its end. The job lasts as long as the child does: it is a
  session's shape (`docs/design/concurrency.md`, "A long-lived job owns a
  handed-over child").
- **`echo-attach-cancel`** cancels that job by its key: the request is
  withdrawn at the crate, the child is ended, the crate's consumer reads
  its last event, and the job's command never runs.

The module imports the Rust-backed binding, `Echo.Real`, so that the editor
of a set that holds this package, whose root imports the entry module and
so this module, links the binding and the package's glue, and loads the
package's library when it starts (`Echo.Real`'s initialiser): an editor
whose load is refused exits 1 before its `main`, saying why.
-/

namespace Echo

/-- The name of the job, and of the command, that says a text. -/
def sayName : String :=
  "echo-say"

/-- The name of the job, and of the command, that hands a child over. -/
def attachName : String :=
  "echo-attach"

/-- The name of the command that cancels the job `echo-attach`. -/
def attachCancelName : String :=
  "echo-attach-cancel"

/-- The key the job `echo-attach` runs under. -/
def attachKey : String :=
  "echo-attach"

/-- The text `echo-say` says when it is given none. -/
def sayDefault : String :=
  "hello"

/-- The script of the child `echo-attach` opens: a line, then it lives
until it is ended, as an agent's would. -/
def attachScript : String :=
  "echo one; exec sleep 600"

/-- The child `echo-attach` opens. -/
def attachCommand : Editor.Process.Command :=
  { program := "/bin/sh", arguments := #["-c", attachScript], directory := "/" }

/-- What the echo area says of `say`'s reply. -/
def said : Except Editor.PackageError Reply → String
  | .ok reply => s!"echo: {reply.text} {reply.checksum}"
  | .error refusal => s!"{sayName}: {repr refusal}"

/-- What the echo area says of `attach`'s read. -/
def attachSaid : Except String Attached → String
  | .ok read => s!"{attachName}: {read.text}"
  | .error refusal => s!"{attachName}: {refusal}"

/-- The job `echo-attach`: opens the child and hands it to the crate, and
answers what the crate read. -/
def attachWork : Editor.JobM (Except String Attached) := do
  match ← Editor.Process.start attachCommand { bound := 4 * 1024 * 1024, input := true } with
  | .error refusal =>
    return .error s!"the child was refused: {repr refusal}"
  | .ok child =>
    match ← Job.attach child with
    | .ok read =>
      return .ok read
    | .error refusal =>
      return .error s!"the crate did not take the child: {repr refusal}"

/-- The package `echo`. -/
def package : Editor.Package :=
  { name := "echo"
    setup := do
      Editor.jobWith sayName
          (fun arguments =>
            match arguments with
            | [.str text] => Job.say text
            | _ => Job.say sayDefault)
          fun reply => Editor.message (said reply)
      Editor.commandWith sayName fun call => do
          let text :=
            match call.arguments with
            | .str text :: _ => text
            | _ => sayDefault
          discard <| Editor.startJob sayName [.str text]
      Editor.job attachName (fun _ => attachWork) fun read => Editor.message (attachSaid read)
      Editor.command attachName (discard <| Editor.startJob attachName [] (some attachKey))
      Editor.command attachCancelName (Editor.cancelJob attachKey)
    services := #[Real.service] }

/-- The packages of the Lake package `echo`: `echo`. -/
def packages : Array Editor.Package :=
  #[package]

end Echo
