import AgentsApiTest.Fake
import Editor.Test.Fixture.Support

/-!
# The fixture support of `agents-api`

What `agents-api` brings to the stepped fixture harness of a set that holds
it (`Editor.Test.Fixture.Support`, `lean/Editor/Test/Fixture/Support.lean`):
the fake of its service `agents`, made afresh for each run over the
conversation script (`Fake.fresh Fake.conversation`), so a package's
stepped fixture whose job opens a session talks to the fake as a stepped
check does. The package-set build finds this module by its name and only
the fixture harness's root imports it, so no editor links the fake.
-/

namespace AgentsApiTest.FixtureSupport

/-- The fake of `agents`, over the conversation script, for each run. -/
def support : Editor.Test.Fixture.Support :=
  { name := "agents-api", fakes := #[Fake.fresh Fake.conversation] }

end AgentsApiTest.FixtureSupport
