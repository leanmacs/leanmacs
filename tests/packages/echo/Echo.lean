import Echo.Checksum

/-!
# The fixture package `echo`: its port

A package outside the core, used by tests alone, that holds Rust
(`docs/design/packages.md`, "Rust in a package"): a crate of its own
(`rust/`), with one service, the echo, and the glue that binds it
(`ffi/glue.c`). This module is the port the service is used through, in
the editor's terms and with no Rust: start a request of a text, under an
id the caller chose; cancel it; take its reply once it has completed, the
text and its CRC-32, which the crate takes from the system's zlib; attach a
streaming child a job opened, which the crate takes over and reads, and
take what it read; and flush, once every request before has completed.

Each reply is a named type of the package's that derives `TypeName`
(`Reply`, `Attached`), so a job reads it back from the job port's
`Dynamic` (`Echo/Job.lean`), and no other package's reply can pass for it.

The port has a pure model (`Echo.Model`) and a contract
(`Echo.Contract`), whose properties run against the model in the package's
test driver and against the Rust-backed binding (`Echo.Real`) in its linked
test, where a request completes through the editor's completion queue and
pump.
-/

namespace Echo

/-- What a request answers. -/
structure Reply where
  /-- The request's text, back. -/
  text : String
  /-- The CRC-32 of the text's UTF-8 bytes (`Echo.checksum`). -/
  checksum : UInt32
  deriving DecidableEq, Repr, TypeName

/-- What an attached request read of its child. -/
structure Attached where
  /-- The child's lines, then a last line that says how it ended or that it
  was cancelled, joined by line feeds. -/
  text : String
  /-- How many pulls it took. -/
  pulls : UInt32
  deriving DecidableEq, Repr, TypeName

/-- The echo service, as a package's code sees it: the port. -/
structure Service where
  /-- Starts the request `id` of a text, and says whether it started: it does
  not while `id` is in use, from its start until it is taken or cancelled. -/
  start : UInt64 → String → IO Bool
  /-- Cancels the request `id`, and says whether it was in use. Its reply is
  dropped. -/
  cancel : UInt64 → IO Bool
  /-- The reply to the request `id`, once it has completed, after which `id`
  is no longer in use; `none` before then, and for an id not in use. -/
  take : UInt64 → IO (Option Reply)
  /-- Hands the streaming child `child`, which a job opened, to the service
  as the request `id`, which completes once the child has ended or was
  cancelled; false when the take-over is refused or `id` is in use. -/
  attach : (id child : UInt64) → IO Bool
  /-- What the attached request `id` read, once it has completed, after
  which `id` is no longer in use; `none` before then and for an id not
  attached. -/
  attachTake : UInt64 → IO (Option Attached)
  /-- Asks for `id` to be completed once every request started before has
  completed or been cancelled; an attached request is not waited for. -/
  flush : UInt64 → IO Unit

/-- The name the service is reached by from a job (`Echo/Job.lean`). -/
def serviceName : String :=
  "echo"

/-- The reply to a request of `text`: the text and its checksum. -/
def Reply.to (text : String) : Reply :=
  { text, checksum := Echo.checksum text }

end Echo
