import Acp.Permissions.Outbox
import AcpTest.Check

/-!
# Model tests: `Acp/Permissions/Outbox.lean`

`outboxChecks`: the audit log's outbox, one write at a time: lines added
with none in flight start a write of them all; lines added while one is in
flight start nothing and wait; a finished write drops exactly the lines it
held and starts a write of those that came in meanwhile; and the outbox is
read back from its tree as it was written. The test driver's root,
`AcpTest/Model.lean`, runs them.
-/

namespace AcpTest

open Acp.Permissions

/-- The checks of `Acp/Permissions/Outbox.lean`. -/
def outboxChecks : List Check :=
  [{  name :=
        "lines added with no write in flight start one write of them all, each ended by a line feed"
      run := do
        let (outbox, write) := ({} : Outbox).enqueue #["one", "two"]
        saw
            (write == some { text := "one\ntwo\n", count := 2 } &&
              outbox == { lines := #["one", "two"], writing := some 2 })
            s!"{repr outbox}; {repr write}" },
    { name := "nothing added starts no write"
      run := do
        let (outbox, write) := ({} : Outbox).enqueue #[]
        saw (write == none && outbox == {}) s!"{repr outbox}; {repr write}" },
    { name := "lines added while a write is in flight start nothing and wait behind it"
      run := do
        let (first, _) := ({} : Outbox).enqueue #["one"]
        let (second, write) := first.enqueue #["two", "three"]
        saw (write == none && second == { lines := #["one", "two", "three"], writing := some 1 })
            s!"{repr second}; {repr write}" },
    { name :=
        "a finished write drops exactly the lines it held and starts one write of those that came in meanwhile"
      run := do
        let (first, _) := ({} : Outbox).enqueue #["one"]
        let (second, _) := first.enqueue #["two", "three"]
        let (after, write) := second.wrote 1
        saw
            (write == some { text := "two\nthree\n", count := 2 } &&
              after == { lines := #["two", "three"], writing := some 2 })
            s!"{repr after}; {repr write}" },
    { name := "a finished write with nothing behind it leaves the outbox empty and starts nothing"
      run := do
        let (first, _) := ({} : Outbox).enqueue #["one", "two"]
        let (after, write) := first.wrote 2
        saw (write == none && after == {}) s!"{repr after}; {repr write}" },
    { name :=
        "the outbox is read back from its tree as it was written, with a write in flight or none"
      run := do
        let held : List Outbox := [{}, { lines := #["a\tb", "c"], writing := some 1 }]
        let read := held.map fun outbox => Outbox.decode outbox.encode
        saw (read == held.map some) s!"{repr read}" }]

end AcpTest
