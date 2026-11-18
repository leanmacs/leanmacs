import Editor.Ffi.Events
import Editor.Ffi.Text
import FfiTest.Check
import FfiTest.Support.Queues

/-!
# FFI tests: `Editor/Ffi/Events.lean`

The tests of `Editor/Ffi/Events.lean`: `dataChecks`, `queueChecks` and
`shutdownChecks`, and `blockForGood`, which the `exit-while-blocked` scenario
parks. The root module `FfiTest` runs them, and each list's own doc says what it
checks.
-/

namespace FfiTest

/-- Text whose byte offsets and character counts differ: "é" and "ö" are two
bytes each. -/
def haystack : String :=
  "héllo wörld, hello"

/-- The checks of plain data: an option and a byte range (`Editor.Ffi.find`),
and a string, enums and a small structure (an event), in both directions. -/
def dataChecks (_ : Unit) : List Check :=
  [{ name := "find returns the byte range of the first match",
     run := pure (Editor.Ffi.find haystack "llo" == some { start := 3, stop := 6 }) },
    { name := "find starts looking at the start offset it is given"
      run := pure (Editor.Ffi.find haystack "llo" (some 4) == some { start := 17, stop := 20 }) },
    { name := "find returns none when there is no match from a usable start"
      run :=
        pure
          (Editor.Ffi.find haystack "zzz" == none &&
            Editor.Ffi.find haystack "llo" (some 2) == none &&
            Editor.Ffi.find haystack "llo" (some 21) == none) },
    { name := "an event posted to a queue is pulled back whole"
      run := roundTrips 7 42 "héllo wörld" },
    { name := "an event's text keeps an embedded NUL byte"
      run := roundTrips 8 43 "before\x00after" },
    { name := "an event with empty text and the largest code crosses"
      run := roundTrips 9 0xFFFFFFFFFFFFFFFF "" },
    { name := "a message posted from Lean has no stamp"
      run := do
        unless ← Editor.Ffi.postEvent .editor 10 1 "" do
          return false
        return ((← pull .editor).map (·.stamp)) == some 0 },
    { name := "the tag of a completion is known"
      run := pure (Editor.Ffi.EventKind.ofTag? 2 == some .completion) },
    { name := "the tags of a window's events and of the window source are known"
      run :=
        pure
          ((([3, 4, 5, 6, 7, 8, 9, 10, 11, 12] : List UInt64).map Editor.Ffi.EventKind.ofTag?) ==
              [some .windowOpened, some .windowFocus, some .key, some .composition, some .pointer,
                some .closeRequested, some .resize, some .openFiles, some .quitRequested,
                some .menu] &&
            Editor.Ffi.SourceKind.ofTag? 3 == some .window) },
    { name := "the tag of a parse delivered is known"
      run := pure (Editor.Ffi.EventKind.ofTag? 13 == some .parsed) },
    { name := "a tag the bindings do not know is refused"
      run :=
        pure ((Editor.Ffi.EventKind.ofTag? 14).isNone && (Editor.Ffi.SourceKind.ofTag? 4).isNone) }]

/-- The checks of the two event queues: Rust threads push, Lean pulls. -/
def queueChecks (_ : Unit) : List Check :=
  [{ name := "events posted to a queue are pulled from that queue, in order",
     run := do
       let first ← Editor.Ffi.postEvent .editor 5 1 ""
       let other ← Editor.Ffi.postEvent .completion 5 2 ""
       let second ← Editor.Ffi.postEvent .editor 5 3 ""
       -- The completion queue first: were the two one queue, this would be
       -- the first event posted.
       let fromCompletion ← pull .completion
       let fromEditor := [← pull .editor, ← pull .editor]
       return first && other && second && fromCompletion == some (message 5 2 "") &&
           fromEditor == [some (message 5 1 ""), some (message 5 3 "")] },
    { name := "a pull parks until an event is posted to its queue"
      run := do
        let task ← IO.asTask (prio := .dedicated) (Editor.Ffi.nextEvent .completion)
        let parked ← eventually (return (← Editor.Ffi.waiting .completion) == 1)
        let othersParked ← Editor.Ffi.waiting .editor
        let finishedEarly ← IO.hasFinished task
        let posted ← Editor.Ffi.postEvent .completion 6 1 "wake"
        let woken ← eventually (IO.hasFinished task)
        unless parked && othersParked == 0 && !finishedEarly && posted && woken do
          return false
        return (← IO.ofExcept task.get) == message 6 1 "wake" },
    { name := "a script fed from a Rust thread arrives in order, tagged with its source"
      run := do
        unless ← Editor.Ffi.feedScript .completion 9 3 do
          return false
        for code in ([0, 1, 2] : List UInt64) do
          let some event ← pull .completion | return false
          unless
            event.source == { kind := .script, id := 9 } && event.kind == .message &&
              event.code == code do
            return false
        return true },
    { name :=
        "an event's words cross whole and in order: each scripted event carries its code and the largest word less its code"
      run := do
        unless ← Editor.Ffi.feedScript .completion 9 2 do
          return false
        let first ← pull .completion
        let second ← pull .completion
        return (first.map (·.words)) == some #[0, 0xFFFFFFFFFFFFFFFF] &&
            (second.map (·.words)) == some #[1, 0xFFFFFFFFFFFFFFFE] },
    { name := "an event posted from Lean has no words"
      run := do
        unless ← Editor.Ffi.postEvent .editor 12 1 "" do
          return false
        return ((← pull .editor).map (·.words)) == some #[] }]

/-- The checks of shutdown, run by `ffi-test shutdown` in a process of their
own because quit is for good. They run in order: the first quits the queues. -/
def shutdownChecks (_ : Unit) : List Check :=
  [{ name := "quit wakes a task parked on each queue with a quit event",
     run := do
       let editor ← IO.asTask (prio := .dedicated) (Editor.Ffi.nextEvent .editor)
       let completion ← IO.asTask (prio := .dedicated) (Editor.Ffi.nextEvent .completion)
       let parked ←
         eventually do
             return (← Editor.Ffi.waiting .editor) == 1 && (← Editor.Ffi.waiting .completion) == 1
       Editor.Ffi.quit
       let returned ←
         eventually do
             return (← IO.hasFinished editor) && (← IO.hasFinished completion)
       unless parked && returned do
         return false
       let woken := [← IO.ofExcept editor.get, ← IO.ofExcept completion.get]
       return woken.all (·.kind == .quit) },
    { name := "after quit every pull returns a quit event at once"
      run := do
        let pulled := [← pull .editor, ← pull .completion, ← pull .editor]
        return pulled.all fun event => (event.map (·.kind)) == some .quit },
    { name := "after quit a post is refused"
      run := return !(← Editor.Ffi.postEvent .editor 1 1 "after quit") }]

/-- Parks a dedicated task in a pull that nothing will ever wake. `true` once
it is parked. -/
def blockForGood : IO Bool := do
  discard <| IO.asTask (prio := .dedicated) (Editor.Ffi.nextEvent .editor)
  eventually (return (← Editor.Ffi.waiting .editor) == 1)

end FfiTest
