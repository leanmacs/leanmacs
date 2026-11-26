import Editor.Job.Fake
import Editor.Test.Fixture.Setup

/-!
# The headless fixture harness: a package's fixture support

What a Lake package of a set brings to the stepped fixture harness for its
own fixtures (`docs/dev-practices/headless-mode.md`, "A package's
fixtures"): the setups of its fixtures' scripts (`Support.setups`, keyed as
the core's are, by the script's path from the repository's root) and the
fakes of the package services its fixtures' jobs ask (`Support.fakes`, each
a package's own fake, `Job.PackageFake`). Without one, a stepped run has no
service a package brings (the stepped host's package services are its
fakes alone), and a package's fixture could script no child.

A package declares it as `support : Editor.Test.Fixture.Support` in its
module `<P>Test.FixtureSupport`, which the package-set build finds as it
finds an entry module, by its name (`fixtureSupportModule?` in
`lean/lakefile.lean`), and the generated root of the set's fixture harness
alone imports and hands on (`fixturesRootSource`). The editor's root
imports none, so no fake is linked into an editor.

`Support.merge` puts the core's setups first, then each support's in the
set's order, and gathers every support's fakes; a script with two setups
is refused, naming both declarers, never shadowed.

Pure: model-test pins it (`ModelTest/Editor/Test/Fixture/Support.lean`).
-/

namespace Editor.Test.Fixture

/-- What a package brings to the stepped fixture harness (the module
docs). -/
structure Support where
  /-- Who declares it, for a refusal: the package's name. -/
  name : String
  /-- The setups of its fixtures, by script path from the repository's
  root. -/
  setups : Array (String × Setup) := #[]
  /-- The fakes of the package services its fixtures' jobs ask, each made
  afresh by each run. -/
  fakes : Array Job.PackageFake := #[]

/-- The setups and fakes of one harness: the core's setups `core`, then those
of each of `supports` in order, and every support's fakes; or, for a script
two of them declare a setup of, why not, naming the script and both. -/
def Support.merge (supports : Array Support) (core : Array (String × Setup) := Setup.core) :
    Except String (Array (String × Setup) × Array Job.PackageFake) := do
  let mut setups : Array (String × String × Setup) :=
    core.map fun (script, setup) => (script, "the core", setup)
  let mut fakes := #[]
  for support in supports do
    for (script, setup) in support.setups do
      if let some (_, first, _) := setups.find? (·.1 == script) then
        throw s!"the fixture {script} has a setup from both {first} and {support.name}"
      setups := setups.push (script, support.name, setup)
    fakes := fakes ++ support.fakes
  return (setups.map fun (script, _, setup) => (script, setup), fakes)

end Editor.Test.Fixture
