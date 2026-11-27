import ContractTest.Check
import Editor.UrlOpener
import Editor.UrlOpener.Real

/-!
# Contract tests: `Editor/UrlOpener/Real.lean`

The tests of `Editor/UrlOpener/Real.lean`: `urlOpenerChecks`, what crosses
the boundary to the library's URL opener, over its recording and failing
openers, so nothing is launched. The root module `ContractTest` runs them;
its module doc says what each shows.
-/

namespace ContractTest

open Editor

/-- The reason the library's failing opener is made with in
`urlOpenerChecks`: not ASCII, so a reason cut or mis-decoded at the glue
shows. -/
def urlOpenerReason : String :=
  "aucun gestionnaire: é"

/-- What the job port's URL opener properties cannot show of the real
binding: what a recording opener reads back, a refusal's reason as it
crosses. That each opener is freed is the library's
(`crates/editor-ffi/tests/url_opener.rs`). -/
def urlOpenerChecks : List Check :=
  [{  name :=
        "a recording opener of the library's reads back each URL it was handed, in order and intact, an empty one among them, and starts with none"
      run := do
        let real ← UrlOpener.Real.recording
        let before ← real.opened
        let urls := #["https://example.com/a b?x=1&y=2#frag", "", "https://例え.jp/é"]
        let answers ← urls.mapM fun url => real.handle (.openUrl url)
        return before == some #[] && answers.all (· matches .ok ()) &&
            (← real.opened) == some urls },
    { name :=
        "a failing opener of the library's answers every URL its reason, not ASCII, intact, and reads back nothing"
      run := do
        let real ← UrlOpener.Real.failing urlOpenerReason
        let answer ← real.handle (.openUrl "https://example.com")
        return (match answer with
            | .error reason => reason == urlOpenerReason
            | .ok () => false) &&
            (← real.opened).isNone }]

end ContractTest
