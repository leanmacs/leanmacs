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

The job port has no request yet. A job computes, and what it may wait for (a
process, a file, a timer) arrives as requests of this port with the job
system, each with its reply type, a model and a real handler, the way the
text port grows. That a wait is not a command is checked here once the first
such request exists: until then "a command may not block" is checked only as
far as `IO` goes.
-/

namespace Editor

/-- What a job may ask for while it runs. Nothing yet: the services a job can
wait on arrive with the job system, as constructors here. -/
inductive JobRequest

/-- The type of the reply to each request of a job. There is no request, so
there is no reply. -/
def JobRequest.Reply : JobRequest → Type :=
  nofun

/-- The job port: `JobRequest` and the reply to each request. -/
abbrev jobPort : Port :=
  { Request := JobRequest, Reply := JobRequest.Reply }

/-- A job: a program over the job port. It may wait, and it cannot change
editor state: the job port has no request that does, and the editor's
requests are not requests of it. -/
abbrev JobM :=
  Program jobPort

/-! ## The split, checked when this module is compiled

Each check below is an `example` that builds only while a violation of the
split is a type error. `fail_if_success` succeeds when the term in it fails to
elaborate, for whatever reason, so each check says the type the violation is
offered at, and the two examples that come first show that a legal term is
accepted at each of those types. A check that still builds with a legal term
in place of its violation is offered at the wrong type. -/

example : True :=
  (fun (_ : JobM Unit) => True.intro) (pure ())

example : True :=
  (fun (_ : EditorM Unit) => True.intro) ((⟨0⟩ : TextId).insert 0 "x")

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

end Editor
