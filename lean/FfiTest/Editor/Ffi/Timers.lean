import Editor.Ffi.Events
import Editor.Ffi.Timers
import FfiTest.Check
import FfiTest.Support.Queues

/-!
# FFI tests: `Editor/Ffi/Timers.lean`

The tests of `Editor/Ffi/Timers.lean`: `timerChecks`. The root module `FfiTest`
runs them, and each list's own doc says what it checks.
-/

namespace FfiTest

/-- An hour, in milliseconds: a deadline no check reaches. -/
def hour : UInt64 :=
  3600000

/-- The checks of the timer service's bindings: a request with an id goes
in, and its completion comes back as an event on the completion queue. -/
def timerChecks (_ : Unit) : List Check :=
  [{
      name :=
        "a timer request that is due comes back as a completion on the completion queue, from the library, with the request's id as its code",
      run := do
        let accepted ← Editor.Ffi.timersStart 7 (← Editor.Ffi.timersNow)
        let some event ← pull .completion | return false
        return accepted && event.source.kind == .library && event.kind == .completion &&
            event.code == 7 &&
            event.text == "" },
    { name :=
        "a timer request an hour away waits until it is cancelled: an id that is waiting is refused, and a cancel says whether the request was waiting"
      run := do
        let before ← Editor.Ffi.timersPending
        let accepted ← Editor.Ffi.timersStart 8 ((← Editor.Ffi.timersNow) + hour)
        let again ← Editor.Ffi.timersStart 8 0
        let waiting ← Editor.Ffi.timersPending
        let cancelled ← Editor.Ffi.timersCancel 8
        let twice ← Editor.Ffi.timersCancel 8
        let never ← Editor.Ffi.timersCancel 99
        return accepted && !again && waiting == before + 1 && cancelled && !twice && !never &&
            (← Editor.Ffi.timersPending) == before },
    { name :=
        "a timer flush asked behind a wait that is due is completed after it, and does not wait for one an hour away"
      run := do
        let due ← Editor.Ffi.timersStart 9 (← Editor.Ffi.timersNow)
        let later ← Editor.Ffi.timersStart 10 ((← Editor.Ffi.timersNow) + hour)
        let flushing ← Editor.Ffi.timersFlush 11
        let first ← pull .completion
        let second ← pull .completion
        let waiting ← Editor.Ffi.timersCancel 10
        return due && later && flushing && (first.map (·.code)) == some 9 &&
            (second.map (·.code)) == some 11 &&
            waiting },
    { name := "the timer clock does not go back"
      run := do
        let first ← Editor.Ffi.timersNow
        return first <= (← Editor.Ffi.timersNow) }]

end FfiTest
