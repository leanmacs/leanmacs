import Editor.Lint.Wait

/-!
# Bindings: the timer service

The bindings of `crates/editor-ffi/src/timers.rs`. The conventions they
follow, and the tests that pin each, are in the module docs of
`Editor/Ffi.lean` ("Services and completions").
-/

namespace Editor.Ffi

/-- The time on the library's timer clock, in milliseconds since the clock
began. It never goes back. -/
@[extern "editor_glue_timers_now"]
opaque timersNow : IO UInt64

/-- Asks the library's timer service to complete the request `id` once its
clock reads `deadline` or later, and returns whether it was accepted. It
returns at once. The completion is a `completion` event on the completion
queue whose code is `id`; there is none if the request is cancelled first.

`false`, with nothing started, if `id` is already waiting or the service
could not start its thread. -/
@[extern "editor_glue_timers_start"]
opaque timersStart (id deadline : UInt64) : IO Bool

/-- Withdraws the timer request `id`, and returns whether it was waiting. It
is safe for an id that is unknown or already completed. A completion that
was already queued still arrives. -/
@[extern "editor_glue_timers_cancel"]
opaque timersCancel (id : UInt64) : IO Bool

/-- Asks the timer service for the request `id` to be completed once every
wait due when this is called has been completed, and returns whether it was
accepted. It returns at once. Its completion is queued behind those of the
waits it covers; a wait not yet due is not covered. -/
@[extern "editor_glue_timers_flush"]
opaque timersFlush (id : UInt64) : IO Bool

/-- How many timer requests are waiting. A readout for tests, which use it to
see that a request reached the service and that a cancel removed it. -/
@[extern "editor_glue_timers_pending",
  inferred_wait count Editor.Job.Real Editor.Job.Contract Editor.Job.FlushContract
      Editor.Job.HandleContract Editor.Test.Linked.Services]
opaque timersPending : IO UInt64

end Editor.Ffi
