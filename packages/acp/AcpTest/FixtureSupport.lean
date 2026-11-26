import Acp.ClaudeCode
import Editor.Test.Fixture.Support

/-!
# The fixture support of `acp`

What `acp` brings to the stepped fixture harness of a set that holds it
(`Editor.Test.Fixture.Support`, `lean/Editor/Test/Fixture/Support.lean`):
the setup of its conversation fixture (`tests/headless/conversation/`),
whose git answers as outside a repository in the run's working directory,
`/work/lean`, which is a workspace by its marker `lakefile.lean`, and whose
agent's child is the process fake's, started with exactly the command the
session job starts (`Acp.claudeCode.command`) and paused for ever, as an
agent lives until it is ended. The session's service is `agents-api`'s
support's fake. The package-set build finds this module by its name and
only the fixture harness's root imports it.
-/

namespace AcpTest.FixtureSupport

open Editor
open Editor.Test.Fixture

/-- The conversation fixture's script, from the repository's root. -/
def conversationScript : String :=
  "packages/acp/tests/headless/conversation/script"

/-- The agent's child of the conversation fixture, paused for ever. -/
def agentChild : Process.StreamScript :=
  { command := Acp.claudeCode.command defaultWorkingDirectory, steps := #[.pause 1000000000] }

/-- The setup of the conversation fixture. -/
def support : Support :=
  { name := "acp"
    setups :=
      #[(conversationScript,
          { processes := { gitOutside defaultWorkingDirectory with streams := #[agentChild] } })] }

end AcpTest.FixtureSupport
