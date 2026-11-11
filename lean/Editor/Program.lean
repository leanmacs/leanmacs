/-!
# Programs over a port

An interface between the editor and a collaborator is a *port*: a type of
requests and, for each request, the type of its reply. Editor logic is a
*program* over a port. A program is plain data: it is finished, or it makes a
request and continues with the reply. It holds no `IO` and calls nothing, so
the only way it touches anything is by being run against a handler, which
answers its requests.

A port has two handlers. Its pure model is a function from a request and the
model's state to a reply and a new state, and `Program.run` runs a program
against it: that is what tests run, and what theorems are stated about. Its
real binding answers each request with a call into the Rust library, in `IO`,
and `Program.runM` runs the same program against it.

`Program port α` is in `Type`: it is indexed by a request type with a reply
type per request, not by a functor. So a program can be the result of an `IO`
action, sit in a reference, and be fetched from interpreted config at one
concrete type.

A port value is an `abbrev`, so that a handler written over the request type
itself (`(request : TextRequest) → …`) is accepted where one over
`port.Request` is expected.
-/

namespace Editor

/-- A port: the requests the editor can make of a collaborator, and the type
of the reply to each one. -/
structure Port where
  /-- The requests. -/
  Request : Type
  /-- The type of the reply to a request. -/
  Reply : Request → Type

/-- A program that reaches the outside only through `port` and, when it
finishes, returns an `α`. -/
inductive Program (port : Port) (α : Type) : Type where
  /-- The finished program, whose value is `value`. -/
  | done (value : α)
  /-- Makes `request`, then continues as `next` applied to its reply. -/
  | step (request : port.Request) (next : port.Reply request → Program port α)

namespace Program

variable {port : Port} {α β σ : Type} {m : Type → Type}

/-- The program that runs `program`, then `after` applied to its value. -/
protected def bind : Program port α → (α → Program port β) → Program port β
  | .done value, after => after value
  | .step request next, after => .step request fun reply => (next reply).bind after

instance : Monad (Program port) where
  pure := .done
  bind := Program.bind

/-- The program that makes one request and returns its reply. -/
def request (request : port.Request) : Program port (port.Reply request) :=
  .step request .done

/-- Runs a program against a pure handler, from the state `state`: each
request goes to `handle` with the state so far, and its reply to the program.
Returns the program's value and the state after its last request.

This is how a program runs against a port's model. -/
def run (handle : (request : port.Request) → σ → port.Reply request × σ) :
    Program port α → σ → α × σ
  | .done value, state => (value, state)
  | .step request next, state =>
    let (reply, state) := handle request state
    (next reply).run handle state

/-- Runs a program against a handler in the monad `m`: each request goes to
`handle`, and its reply to the program. Returns the program's value.

This is how a program runs against a port's real binding, at `IO` or a state
monad over it. -/
def runM [Monad m] (handle : (request : port.Request) → m (port.Reply request)) :
    Program port α → m α
  | .done value => pure value
  | .step request next => do
    let reply ← handle request
    (next reply).runM handle

end Program

end Editor
