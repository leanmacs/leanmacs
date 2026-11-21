/-!
# The editor queue, as a port

What a Lean poster hands the editor queue (`Posted`), and the queue as a
port (`Queue`): how a post is handed over, and who takes what is posted
(`Queue.Puller`). Two queues are of it:

- the library's editor queue (`Queue.library`, `Editor/Headless/Queue/Real.lean`),
  which the real loop pulls on its own thread (`Headless.loop`); its binding
  is the only queue module that imports `Editor.Ffi`;
- an in-memory queue (`Queue.Memory`), which a host stepped on its caller's
  thread drains (`Editor/Headless/Stepped.lean`).

This module imports nothing that imports `Editor.Ffi`, so the model tests,
which link no library, run the queue's contract against the memory queue
(`Editor/Headless/Queue/Contract.lean`).

The memory queue is one reference, each step one atomic change of it, so
pool and dedicated tasks may post into it while one thread takes: a FIFO of
any `α`, with at most one waiter for the next push (`arrived`), and a
`close` after which every push is refused.
-/

namespace Editor.Headless

/-- What a Lean poster hands the editor queue: the source id it posts
under, a code and a text. -/
structure Posted where
  /-- The Lean source id. -/
  source : UInt64
  /-- A number whose meaning the source sets. -/
  code : UInt64
  /-- A text whose meaning the source sets. -/
  text : String := ""
  deriving DecidableEq, Repr, Inhabited

/-- Who takes what is posted to a queue. -/
inductive Queue.Puller where
  /-- The real loop, on its own thread, through the library's editor queue. -/
  | library
  /-- A stepped host's drain, on its caller's thread. -/
  | stepper
  deriving DecidableEq, Repr

/-- The editor queue, as the core posts to it. -/
structure Queue where
  /-- Hands `posted` to the queue; whether it took it. Refused once the
  queue is closed or quit. Never throws. -/
  post : Posted → BaseIO Bool
  /-- Who takes what is posted. -/
  pulledBy : Queue.Puller

/-- What `Queue.Memory` holds. -/
structure Queue.Memory.State (α : Type) where
  /-- The oldest items, oldest first. -/
  front : List α := []
  /-- The newest items, newest first. -/
  back : List α := []
  /-- The waiter the next push wakes, if one is armed (`arrived`). -/
  waiter : Option (IO.Promise Unit) := none
  /-- Whether the queue was closed: every push after it is refused. -/
  closed : Bool := false

/-- An in-memory FIFO of `α`, safe for posts from any task: one reference,
each step one atomic change of it. -/
structure Queue.Memory (α : Type) where private mk ::
  /-- The queue's one reference. -/
  state : IO.Ref (Queue.Memory.State α)

namespace Queue.Memory

variable {α : Type}

/-- An empty queue, open, with no waiter. -/
def new : BaseIO (Queue.Memory α) :=
  return ⟨← IO.mkRef {}⟩

/-- Wakes `waiter`, if there is one. -/
private def wake (waiter : Option (IO.Promise Unit)) : BaseIO Unit := do
  if let some waiter := waiter then
    waiter.resolve ()

/-- Adds `item` at the back and wakes the waiter; `false`, adding nothing,
once the queue is closed. -/
def push (queue : Queue.Memory α) (item : α) : BaseIO Bool := do
  let (taken, waiter) ←
    queue.state.modifyGet fun held =>
        if held.closed then ((false, none), held)
        else
          ((true, held.waiter),
            { held with
              back := item :: held.back, waiter := none })
  wake waiter
  return taken

/-- Takes the oldest item, if there is one. -/
def take? (queue : Queue.Memory α) : BaseIO (Option α) :=
  queue.state.modifyGet fun held =>
    match held.front with
    | item :: rest => (some item, { held with front := rest })
    | [] =>
      match held.back.reverse with
      | item :: rest =>
        (some item,
          { held with
            front := rest, back := [] })
      | [] => (none, held)

/-- How many items the queue holds. -/
def size (queue : Queue.Memory α) : BaseIO Nat := do
  let held ← queue.state.get
  return held.front.length + held.back.length

/-- A task that ends at the next push, or at the close: a push before this
call does not end it, so a taker reads the queue after it, and a push it
missed then ends the task. Arms the one waiter. -/
def arrived (queue : Queue.Memory α) : BaseIO (Task Unit) := do
  let fresh ← IO.Promise.new
  let armed ←
    queue.state.modifyGet fun held =>
        if held.closed then (none, held)
        else
          match held.waiter with
          | some waiter => (some waiter, held)
          | none => (some fresh, { held with waiter := some fresh })
  match armed with
  | none =>
    return Task.pure ()
  | some waiter =>
    return waiter.result?.map (sync := true) fun _ => ()

/-- Closes the queue: every later push is refused, and the waiter is woken.
What it holds can still be taken. -/
def close (queue : Queue.Memory α) : BaseIO Unit := do
  let waiter ←
    queue.state.modifyGet fun held =>
        (held.waiter,
          { held with
            closed := true, waiter := none })
  wake waiter

/-- The queue port over `queue`: each post is made into an item by `into`,
and a stepper takes them (`pulledBy := .stepper`). -/
def queue (memory : Queue.Memory α) (into : Posted → α) : Queue where
  post posted := memory.push (into posted)
  pulledBy := .stepper

end Queue.Memory

end Editor.Headless
