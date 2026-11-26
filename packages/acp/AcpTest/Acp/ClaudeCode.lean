import Acp.ClaudeCode
import Acp.Conversation
import AcpTest.Check
import Editor.Config.Packages

/-!
# Model tests: `Acp/ClaudeCode.lean`, and what `Acp.setup` registers

`claudeCodeChecks`: Claude Code's adapter is `claude-agent-acp` with no
arguments, the editor's environment untouched and no MCP server, so its
child's environment has no `CLAUDE_CONFIG_DIR` of the editor's; and a
package whose setup is `Acp.setup`, registered alone as a host registers
it (`Config.State.ofPackages`), registers it at `AgentsApi.Agent`, the
default view at `AgentsApi.ConversationView`, the default policy, which
asks, at `AgentsApi.PermissionPolicy`, the session and queue commands, their
jobs and the conversation's and the queue's modes, with nothing refused. The test driver's
root, `AcpTest/Model.lean`, runs them; it imports nothing of the crate's
binding, so it builds `Acp.setup`'s package here rather than taking
`Acp.package`.
-/

namespace AcpTest

open Editor
open AgentsApi

/-- The package `acp` as its setup registers it, without the crate's
service, which this driver does not link. -/
def conversationPackage : Package :=
  { name := "acp", setup := Acp.setup }

/-- The values `package` registers at the extension point `α`, in order. -/
def registeredAt (α : Type) [TypeName α] (package : Package) : Array α :=
  package.registered.extensions.filterMap fun (key, value) =>
    if key == TypeName.typeName α then value.get? α else none

/-- The checks of Claude Code's registration. -/
def claudeCodeChecks : List Check :=
  [{  name :=
        "Claude Code's adapter is claude-agent-acp with no arguments, an environment that clears, sets and unsets nothing, so no CLAUDE_CONFIG_DIR, and no MCP server; its command runs in the session's root"
      run := do
        let agent := Acp.claudeCode
        let command := agent.command "/work/example"
        saw
            (agent.name == "claude-code" && agent.program == "claude-agent-acp" &&
              agent.arguments.isEmpty &&
              agent.environment == {} &&
              !agent.environment.clear &&
              agent.environment.set.isEmpty &&
              agent.environment.unset.isEmpty &&
              agent.mcpServers.isEmpty &&
              command ==
                { program := "claude-agent-acp", directory := "/work/example" : Process.Command })
            s!"{repr agent}" },
    { name :=
        "acp's setup registers Claude Code's adapter, which a choice finds as claude-code, the default view, which a choice finds by the default name, and the default policy, which asks"
      run := do
        let agents := registeredAt Agent conversationPackage
        let views := registeredAt ConversationView conversationPackage
        let policies := registeredAt PermissionPolicy conversationPackage
        let chosen := Agent.choose agents Acp.defaultAgent
        let request : PermissionRequest :=
          { agent := Acp.defaultAgent, root := "/work/example", sessionId := "sess-0001"
            ticket := 1, turn := none, call := { id := "call-1" }
            options := #[{ id := "allow-once", name := "Yes", kind := "allow_once" }] }
        let policy := PermissionPolicy.choose policies
        saw
            (agents == #[Acp.claudeCode] && chosen == some Acp.claudeCode && views.size == 1 &&
              (ConversationView.choose views).map (·.name) == some ConversationView.defaultName &&
              policies.size == 1 &&
              (policy.map (·.name)) == some PermissionPolicy.defaultName &&
              (policy.map (·.answer request)) == some none)
            s!"agents {repr agents}, views {views.size}, policies {policies.size}" },
    { name :=
        "acp's package registers alone with nothing refused: its session, queue and agents list commands, its jobs agent-session, agent-send, agent-audit and agent-stall, the codec of the agent table, the mode agent-conversation, whose toggle is agent-toggle, the mode agent-permissions, whose localleader a answers, and the mode agent-list, whose localleader o visits"
      run := do
        let (state, refused) : Config.State Unit Unit × Array String :=
          Config.State.ofPackages #[conversationPackage]
        let registry := state.registry
        let commands :=
          [Acp.Conversation.startName, Acp.Conversation.promptName, Acp.Conversation.answerName,
            Acp.Conversation.cancelName, Acp.Conversation.stopName, Acp.Conversation.toggleName,
            Acp.Conversation.openedName, Acp.Conversation.eventsName, Acp.Conversation.queueName,
            Acp.Conversation.queueAnswerName, Acp.Conversation.listName, Acp.Conversation.visitName]
        saw
            (refused.isEmpty && commands.all (fun name => (registry.find? name).isSome) &&
              [Acp.Conversation.sessionJob, Acp.Conversation.sendJob, Acp.Permissions.auditJob,
                    Acp.Table.stallJob].all
                (fun name => registry.jobs.any (·.registration.name == name)) &&
              conversationPackage.registered.codecs.any (·.name == AgentsApi.Table.store.name) &&
              (registry.modes.any fun entry =>
                entry.mode.name == Acp.Table.modeName &&
                  entry.mode.locals == [("o", Acp.Conversation.visitName)]) &&
              (registry.modes.any fun entry =>
                entry.mode.name == Acp.Conversation.modeName &&
                  entry.mode.roles == [(Role.toggle, Acp.Conversation.toggleName)]) &&
              registry.modes.any fun entry =>
                entry.mode.name == Acp.Permissions.modeName &&
                  entry.mode.locals == [("a", Acp.Conversation.queueAnswerName)])
            s!"refused {refused}" }]

end AcpTest
