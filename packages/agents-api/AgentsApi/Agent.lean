import Editor.Extension
import Editor.Process

/-!
# The agent registration point

An agent the editor can start a session with, registered at the extension
point `AgentsApi.Agent` (`Extension.add`) and chosen by its name
(`AgentsApi.Agent.named`): the latest registered under that name, config's
after a package's (`docs/design/extension-points.md`, "A hook, or a
choice"). Everything a session is started with is passed explicitly: the
program, its arguments, its environment and the MCP servers the session is
given. There is no field for a session mode or for the agent's own
configuration, so a registration cannot pass one: the host's Claude
settings are used as they are (roadmap Decisions).
-/

namespace AgentsApi

/-- An MCP server a session is given, run by the agent as a child of its
own. -/
structure McpServer where
  /-- Its name, as the agent shows it. -/
  name : String
  /-- The command the agent runs. -/
  command : String
  /-- Its arguments. -/
  arguments : Array String := #[]
  /-- The variables of its environment, each a name and a value. -/
  environment : Array (String × String) := #[]
  deriving DecidableEq, Repr, Inhabited

/-- An agent a session can be started with: the extension point. -/
structure Agent where
  /-- Its name, which a choice finds it by. -/
  name : String
  /-- The program: a bare name, looked up on the `PATH` the child gets, or an
  absolute path. -/
  program : String
  /-- The program's arguments. -/
  arguments : Array String := #[]
  /-- The environment the agent's child gets. -/
  environment : Editor.Process.Environment := {}
  /-- The MCP servers each session is given. -/
  mcpServers : Array McpServer := #[]
  deriving DecidableEq, Repr, TypeName

/-- The latest of `agents` named `name`, as a choice reads the point: so
config's, registered after a package's, replaces it. -/
def Agent.choose (agents : Array Agent) (name : String) : Option Agent :=
  agents.findRev? (·.name == name)

/-- The agent registered under `name`, the latest of that name. -/
def Agent.named (name : String) : Editor.EditorM (Option Agent) :=
  Editor.Extension.named Agent (·.name) name

/-- The command that starts `agent` in the directory `cwd`. -/
def Agent.command (agent : Agent) (cwd : String) : Editor.Process.Command :=
  { program := agent.program, arguments := agent.arguments, environment := agent.environment
    directory := cwd }

end AgentsApi
