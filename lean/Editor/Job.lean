import Editor.Text

/-!
# Jobs

A job is work that may take as long as it likes: it may block or wait, and it
may not change editor state. A command (`EditorM`, `Editor/Text.lean`) is the
other half: it may change editor state and may not block. They are different
types, so that the type checker keeps each on its side
(`docs/design/concurrency.md`).

`JobM` is the type of programs over the job port, as `EditorM` is of programs
over the editor's port. The two ports share no request, so a text request is
not a job and a job is not a command. A program holds no `IO`, so neither can
smuggle one in.

## The port

A job reaches time, and nothing else yet, through two requests:

- `now` reads the job clock, in milliseconds. The clock only says how far
  apart two readings are: where it starts is the clock's own business.
- `waitUntil deadline` returns once the clock reads `deadline` or later. A
  deadline that has passed returns at once.

`sleep` is written with those two. A job may also fail: `JobM` has an error
layer of messages, so a job has `throw`, `try` and `catch`.

No request carries a promise or a handle: a request is plain data. How a wait
is completed is the runner's business (`Editor/Job/Runner.lean`), not
something a job names.

## Cancellation is not a reply

A job is cancelled at a wait, and from outside: no request has a reply that
says "cancelled", and nothing is thrown into the job. A cancelled job's
continuation is never applied again, so a `try`/`catch` around a wait cannot
resume it, and it runs no cleanup of its own. What it ended as is an
`Job.Outcome`, which is the runner's and the model's to say, not the job's.

## Adding to the port

A new service a job can wait on (a process, a file) is a constructor of
`JobRequest` with its case in `JobRequest.Reply`, and an operation here that
makes the request. It then needs a clause in the model (`JobModel.handle`,
`Editor/Job/Model.lean`), an answer in the runner, and a property in the
contract, which is what pins it for both.

The pieces: the pure model is `Editor/Job/Model.lean`, and `model-test` runs
the checks of it (`ModelTest.jobModelChecks`).
-/

namespace Editor

/-- What a job may ask for while it runs. -/
inductive JobRequest where
  /-- The time on the job clock, in milliseconds. -/
  | now
  /-- Wait until the job clock reads `deadline` or later. -/
  | waitUntil (deadline : Nat)
  deriving DecidableEq, Repr

/-- The type of the reply to each request: the clock's reading for `now`, and
nothing for a wait. No reply says a job was cancelled. -/
def JobRequest.Reply : JobRequest → Type
  | .now => Nat
  | .waitUntil _ => Unit

/-- The job port: `JobRequest` and the reply to each request. -/
abbrev jobPort : Port :=
  { Request := JobRequest, Reply := JobRequest.Reply }

/-- A job: a program over the job port that may fail with a message. It may
wait, and it cannot change editor state: the job port has no request that
does, and the editor's requests are not requests of it. -/
abbrev JobM :=
  ExceptT String (Program jobPort)

/-- The time on the job clock, in milliseconds. -/
def now : JobM Nat :=
  ExceptT.lift (Program.request (port := jobPort) .now)

/-- Waits until the job clock reads `deadline` or later. Returns at once if
it already does. -/
def waitUntil (deadline : Nat) : JobM Unit :=
  ExceptT.lift (Program.request (port := jobPort) (.waitUntil deadline))

/-- Waits for `duration` milliseconds on the job clock. -/
def sleep (duration : Nat) : JobM Unit := do
  waitUntil ((← now) + duration)

namespace Job

/-- How a job ended. -/
inductive Outcome (α : Type) where
  /-- It ran to its end, with this value. -/
  | finished (value : α)
  /-- It threw this message. -/
  | failed (message : String)
  /-- It was cancelled, at a wait or before a request. Whatever it would have
  returned is lost. -/
  | cancelled
  deriving DecidableEq, Repr

end Job

/-! ## The split, checked when this module is compiled

Each check below is an `example` that builds only while a violation of the
split is a type error. `fail_if_success` succeeds when the term in it fails to
elaborate, for whatever reason, so each check says the type the violation is
offered at, and the three examples that come first show that a legal term is
accepted at each of those types, a wait among them. A check that still builds
with a legal term in place of its violation is offered at the wrong type.
Each of the two checks of a wait was seen to bite once by hand: offered at
`JobM Unit`, where a wait is legal, the module stops building. -/

example : True :=
  (fun (_ : JobM Unit) => True.intro) (pure ())

example : True :=
  (fun (_ : EditorM Unit) => True.intro) ((⟨0⟩ : TextId).insert 0 "x")

example : True :=
  (fun (_ : JobM Unit) => True.intro) (sleep 10)

/-! A text request is not a job: alone, and inside a `do` block. -/

example : True := by
  fail_if_success exact (fun (_ : JobM Unit) => True.intro) ((⟨0⟩ : TextId).insert 0 "x")
  trivial

example : True := by
  fail_if_success
    exact
      (fun (_ : JobM Unit) => True.intro)
        (do
          let _ ← (⟨0⟩ : TextId).read
          pure ())
  trivial

/-! An `IO` action is not a job: alone, and inside a `do` block. -/

example : True := by
  fail_if_success exact (fun (_ : JobM Unit) => True.intro) (IO.sleep 10)
  trivial

example : True := by
  fail_if_success
    exact
      (fun (_ : JobM Unit) => True.intro)
        (do
          IO.sleep 10
          pure ())
  trivial

/-! An `IO` action is not a command: alone, and after a text request in a
`do` block. -/

example : True := by
  fail_if_success exact (fun (_ : EditorM Unit) => True.intro) (IO.sleep 10)
  trivial

example : True := by
  fail_if_success
    exact
      (fun (_ : EditorM Unit) => True.intro)
        (do
          (⟨0⟩ : TextId).insert 0 "x"
          IO.sleep 10)
  trivial

/-! A job is not a command. -/

example : True := by
  fail_if_success exact (fun (_ : EditorM Unit) => True.intro) (pure () : JobM Unit)
  trivial

/-! A wait is not a command: alone, and after a text request in a `do` block.
So "a command may not block" is pinned beyond `IO`: the one way a program can
wait is a request of the job port, and a command cannot make it. -/

example : True := by
  fail_if_success exact (fun (_ : EditorM Unit) => True.intro) (sleep 10)
  trivial

example : True := by
  fail_if_success
    exact
      (fun (_ : EditorM Unit) => True.intro)
        (do
          (⟨0⟩ : TextId).insert 0 "x"
          sleep 10)
  trivial

end Editor
