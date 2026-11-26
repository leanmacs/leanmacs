import AgentsApi.Agent

/-!
# Claude Code's adapter, as the agent `acp` registers

The agent the conversation's commands start a session with by default
(`docs/design/agent-hosting.md`, "Sessions and the conversation, as
built"): Claude Code's ACP adapter, `claude-agent-acp`, looked up on the
`PATH` the child gets, with no arguments, the editor's environment as it
is, nothing set, cleared or unset, and no MCP server. So the session's
mode, model, skills and subagents come from the user's own Claude settings,
and the editor sets none of them (roadmap Decisions): there is no field for
a mode or a configuration directory to pass, and `CLAUDE_CONFIG_DIR` is
never set.

`acp` registers it because only an implementation of ACP can drive it, so
it is the default exactly when `acp` is in the user's set. Config replaces
it by registering an `AgentsApi.Agent` of the same name: the latest of a
name is chosen (`AgentsApi.Agent.named`).
-/

namespace Acp

/-- The name of the agent the conversation's commands start. -/
def defaultAgent : String :=
  "claude-code"

/-- Claude Code's ACP adapter, as `acp` registers it: `claude-agent-acp` with
no arguments, the editor's environment, and no MCP server. -/
def claudeCode : AgentsApi.Agent :=
  { name := defaultAgent, program := "claude-agent-acp" }

end Acp
