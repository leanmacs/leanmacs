/-!
# The fixture package `echo`: its port

A package outside the core, used by tests alone, that holds Rust
(`docs/design/packages.md`, "Rust in a package"): a crate of its own
(`rust/`), with one service, the echo, and the glue that binds it
(`ffi/glue.c`). This module is the port the service is used through, in
the editor's terms and with no Rust: start a request of a text, under an
id the caller chose; cancel it; take its reply once it has completed.

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
  deriving DecidableEq, Repr

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

/-- The reply to a request of `text`. -/
def Reply.to (text : String) : Reply :=
  { text }

end Echo
