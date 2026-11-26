import Acp.Conversation.Diff
import AcpTest.Check

/-!
# Model tests: `Acp/Conversation/Diff.lean`

`diffChecks`: the shared head and tail dropped but for two lines of context
each, a pure insertion, a pure deletion, equal texts, a new file, and a
last line with no line feed. The test driver's root, `AcpTest/Model.lean`,
runs them.
-/

namespace AcpTest

open Acp.Conversation

/-- The checks of `Acp/Conversation/Diff.lean`. -/
def diffChecks : List Check :=
  [{  name :=
        "a change in the middle keeps two lines of context on each side and drops the rest of the shared head and tail"
      run := do
        let lines := diffLines (some "a\nb\nc\nd\ne\nf\ng\n") "a\nb\nc\nD\ne\nf\ng\n"
        saw (lines == #["  b", "  c", "- d", "+ D", "  e", "  f"]) s!"{lines}" },
    { name := "the whole-file diff of the adapter shows the edited line with its context"
      run := do
        let lines := diffLines (some "alpha\nbeta\n") "alpha\ngamma\n"
        saw (lines == #["  alpha", "- beta", "+ gamma"]) s!"{lines}" },
    { name := "a pure insertion and a pure deletion show only added or only removed lines"
      run := do
        let inserted := diffLines (some "a\nc\n") "a\nb\nc\n"
        let deleted := diffLines (some "a\nb\nc\n") "a\nc\n"
        saw (inserted == #["  a", "+ b", "  c"] && deleted == #["  a", "- b", "  c"])
            s!"inserted {inserted}, deleted {deleted}" },
    { name := "equal texts show no line, and a new file shows every line added"
      run := do
        let equal := diffLines (some "same\n") "same\n"
        let fresh := diffLines none "one\ntwo\n"
        saw (equal.isEmpty && fresh == #["+ one", "+ two"]) s!"equal {equal}, fresh {fresh}" },
    { name := "a last line with no line feed after it is a change, and says so"
      run := do
        let lines := diffLines (some "alpha\nbeta\n") "alpha\nbeta"
        saw (lines == #["  alpha", "- beta", "+ beta", noLineFeed]) s!"{lines}" }]

end AcpTest
