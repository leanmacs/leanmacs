import ContractTest.Check
import ContractTest.Editor.Headless.Queue.Contract
import Editor.Ffi.Events
import Editor.Headless.Queue
import Editor.Headless.Queue.Real

/-!
# Contract tests: `Editor/Headless/Queue/Real.lean`

What only the editor queue port's real binding shows: `queueRealChecks`.
The event the library hands back for a post is `Posted.toFfi` of it, which
a stepped host's memory queue holds in its place, and the library's queue
says a real loop pulls it. The posts are made under the contract checks'
source id (`queueSource`). The root module `ContractTest` runs them.
-/

namespace ContractTest

open Editor
open Editor.Headless

/-- What only the library's editor queue as the port shows. -/
def queueRealChecks : List Check :=
  [{  name :=
        "the library hands back for each post exactly Posted.toFfi of it: a message of the post's Lean source with its code and text, no words and no stamp"
      run := do
        let posts : List Posted :=
          [{ source := queueSource, code := 0 },
            { source := queueSource, code := 12, text := "é \"x\"" }]
        let mut same := true
        for posted in posts do
          unless ← Queue.library.post posted do
            return false
          same := same && (← pullQueued) == posted.toFfi
        return same },
    { name := "the library's editor queue as the port says a real loop pulls it"
      run := return Queue.library.pulledBy == .library }]

end ContractTest
