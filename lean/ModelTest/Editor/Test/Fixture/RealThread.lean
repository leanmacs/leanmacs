import Editor.Test.Fixture.RealThread
import ModelTest.Check

/-!
# Model tests: `Editor/Test/Fixture/RealThread.lean`

The model tests of the real-thread set as data: `realThreadSetChecks`. The
root module `ModelTest` runs them; its module doc says what they show.
-/

namespace ModelTest

open Editor.Test.Fixture
open Editor.Test.Fixture.RealThread

/-- The checks of the real-thread set's data. -/
def realThreadSetChecks : List Check :=
  [{  name :=
        "the real-thread set is well formed: every script named once, each entry says what it covers and its site, every runner entry is stepped, and every real effect says what"
      run := return problems == #[] && !entries.isEmpty },
    { name :=
        "the well-formedness check names a script named twice, a runner entry not stepped, a real effect that says nothing, and an entry with no covers or no site"
      run := do
        let good : Entry :=
          { script := "t/script", covers := "it", site := "here", subject := .runner, stepped := true }
        let found :=
          problems
            #[good, good, { good with script := "t/b", stepped := false },
              { good with script := "t/c", subject := .realEffect "" },
              { good with script := "t/d", covers := "", site := "" }]
        return found ==
            #["t/script is named twice", "t/b is a runner entry that is not stepped",
              "t/c is a real effect that does not say what", "t/d says nothing it covers", "t/d names no site"] },
    { name :=
        "the runner entries, compared both ways, are tests/headless's script, keys-script, scene-script and ex/script, and no other"
      run :=
        return (compared.map (·.script)) ==
            #["tests/headless/script", "tests/headless/keys-script", "tests/headless/scene-script",
              "tests/headless/ex/script"] },
    { name :=
        "an entry is found by its script, and a script with none finds none: such a fixture runs stepped with the default setup"
      run :=
        return (entry? "tests/headless/restore/abort-script").map (·.stepped) == some false &&
            (entry? "tests/headless/bundle/script").map (·.stepped) == some true &&
            (entry? "tests/headless/keys-script").any (·.subject == .runner) &&
            entry? "tests/headless/tabs/script" == none },
    { name := "every entry not stepped is a real effect: only a real effect is left to the CLI alone"
      run :=
        return entries.all fun entry =>
            entry.stepped ||
              match entry.subject with
              | .realEffect _ => true
              | .runner => false }]

end ModelTest
