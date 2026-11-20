import Echo

/-!
# The contract of the echo port

What every implementation of the port (`Echo.lean`) does, as one list of
properties, run against the pure model (`Echo.Model`) by the package's
test driver and against the Rust-backed binding (`Echo.Real`) by its linked
test. That keeps the model and the service from drifting apart.

A property is run on a subject: the port, where the ids it may use come
from, and whether a request has completed. For the model a request has
completed when its reply is held. For the binding it has completed when the
editor's completion pump has ended the wait of its id, which it does only
for a completion the crate's service posted on the completion queue.
-/

namespace Echo.Contract

/-- What the properties run on. -/
structure Subject where
  /-- The port. -/
  echo : Service
  /-- An id no request has used. -/
  fresh : IO UInt64
  /-- Whether the request `id` has completed, waited for within the
  subject's patience. -/
  completed : UInt64 → IO Bool

/-- One property of the port. -/
structure Property where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Observes the property; `true` when it holds. -/
  holds : Subject → IO Bool

/-- Starts a request of `text` under a fresh id, and gives the id and
whether it started. -/
def started (subject : Subject) (text : String) : IO (UInt64 × Bool) := do
  let id ← subject.fresh
  return (id, ← subject.echo.start id text)

/-- Whether a request of `text`, started, completes and its take answers
its text. -/
def echoes (subject : Subject) (text : String) : IO Bool := do
  let (id, ok) ← started subject text
  return ok && (← subject.completed id) && (← subject.echo.take id) == some (Reply.to text)

/-- The properties every implementation of the port has. -/
def properties : List Property :=
  [{  name := "a started request completes, and its take answers its text and the text's checksum"
      holds := fun subject => echoes subject "hello" },
    { name := "a take answers once; the second answers none"
      holds := fun subject => do
        let (id, ok) ← started subject "once"
        let completed ← subject.completed id
        let first ← subject.echo.take id
        let second ← subject.echo.take id
        return ok && completed && first == some (Reply.to "once") && second == none },
    { name := "text that is not ASCII crosses intact"
      holds := fun subject => echoes subject "héllo, wörld: 日本語 😀" },
    { name := "an id is in use from its start until its take, and a second start with it is refused"
      holds := fun subject => do
        let (id, ok) ← started subject "first"
        let again ← subject.echo.start id "second"
        let completed ← subject.completed id
        let held ← subject.echo.start id "third"
        let taken ← subject.echo.take id
        let free ← subject.echo.start id "fourth"
        let cancelled ← subject.echo.cancel id
        return ok && !again && completed && !held && taken == some (Reply.to "first") && free &&
            cancelled },
    { name := "after a cancel, the take answers none"
      holds := fun subject => do
        let (id, ok) ← started subject "cancelled"
        let cancelled ← subject.echo.cancel id
        return ok && cancelled && (← subject.echo.take id) == none },
    { name := "cancel and take of an unknown id are safe and answer none"
      holds := fun subject => do
        let id ← subject.fresh
        return !(← subject.echo.cancel id) && (← subject.echo.take id) == none },
    { name := "sixteen requests in flight each complete and take their own text"
      holds := fun subject => do
        let texts := (List.range 16).map fun i => s!"request {i}"
        let requests ←
          texts.mapM fun text => do
              let (id, ok) ← started subject text
              return (id, ok, text)
        requests.allM fun (id, ok, text) => do
            return ok && (← subject.completed id) &&
                (← subject.echo.take id) == some (Reply.to text) }]

/-- Runs every property on `subject`, and gives the names of those that do
not hold: none when the subject keeps the contract. A property that throws
does not hold. -/
def failing (subject : Subject) : IO (List String) :=
  properties.filterMapM fun property => do
    let held ←
      try
        property.holds subject
      catch _ =>
        pure false
    return if held then none else some property.name

end Echo.Contract
