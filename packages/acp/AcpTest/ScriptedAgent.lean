import AgentsApiTest.Contract
import Editor.Process

/-!
# The scripted agent executable

An agent the wiring checks run as a real child of the core's process
service: a POSIX `sh` script, run as `/bin/sh -c`, as echo's children are.
It plays `agents-api`'s canonical scenario (`AgentsApiTest/Contract.lean`)
in raw JSON-RPC lines, the same exchange the fake's script plays
(`AgentsApiTest.Fake.canonical`):

- it answers `initialize`, which it accepts only with the client
  capabilities the crate sends, matched as text: `fs` with
  `readTextFile` and `writeTextFile` false, `terminal` false and
  `auth.terminal` false, and nothing else; and then `session/new` (the
  session `sess-0001`, in the mode `mode-ask` of `mode-ask` and
  `mode-auto`);
- the prompt `ask` gives a chunk, the tool call `call-edit-1` and the
  permission request `0` for it;
- the answer `allow` to it gives the call completed and the permission
  request `1` for `call-edit-2`;
- it then waits for both the `cancelled` answer to request `1` and
  `session/cancel`, in either order, answers the prompt `cancelled`, and
  exits 0.

It reads each line with `read -r`, finds what it is with `case` patterns,
and takes a request's id with parameter expansion. The first line it does
not expect makes it exit 3, and so does the end of its input before the
scenario's: so its exit status is its verdict on the client, and a wrong
client fails a check by the child's exit (`ended exited 3`). Lines it does
not expect include an `initialize` that offers `fs` or `terminal` (or any
capability other than the ones above), a `session/set_mode` or any other
request out of the scenario's order, and a second answer to a permission
request. It never sends an `fs/*` or `terminal/*` request, which go from
agent to client, so it checks only what the client offers, not how a
client would answer one. Its parsing depends on the SDK writing a
request's top-level `"id"` before its `params`, and the client
capabilities' fields in the order above, as it does: an SDK that changed
either would fail the checks loudly, by that exit.

Not a Rust binary, which the Lean linked test would need a Cargo build
product of another gate task for; nor Python, which a Mac without the
developer tools lacks.
-/

namespace AcpTest.ScriptedAgent

/-- The script. -/
def script : String :=
  r#"expect() { IFS= read -r line || exit 3; case $line in $1) ;; *) exit 3 ;; esac; }
id_of() { id=${line#*\"id\":\"}; id=${id%%\"*}; }
say() { printf '%s\n' "$1"; }
expect '*"method":"initialize"*"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false,"auth":{"terminal":false}}*'
id_of
say '{"jsonrpc":"2.0","id":"'"$id"'","result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}'
expect '*"method":"session/new"*'
id_of
say '{"jsonrpc":"2.0","id":"'"$id"'","result":{"sessionId":"sess-0001","modes":{"currentModeId":"mode-ask","availableModes":[{"id":"mode-ask","name":"Ask"},{"id":"mode-auto","name":"Auto"}]}}}'
expect '*"method":"session/prompt"*"text":"ask"*'
id_of
prompt=$id
say '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-0001","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"I will edit notes.txt."},"messageId":"msg-1"}}}'
say '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-0001","update":{"sessionUpdate":"tool_call","toolCallId":"call-edit-1","title":"Edit notes.txt","kind":"edit","status":"pending","locations":[{"path":"/work/example/notes.txt"}],"rawInput":{"path":"/work/example/notes.txt"}}}}'
say '{"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{"sessionId":"sess-0001","toolCall":{"toolCallId":"call-edit-1"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"reject","name":"Reject","kind":"reject_once"}]}}'
expect '*"id":0,*"optionId":"allow"*'
say '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-0001","update":{"sessionUpdate":"tool_call_update","toolCallId":"call-edit-1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"Edited."}}]}}}'
say '{"jsonrpc":"2.0","id":1,"method":"session/request_permission","params":{"sessionId":"sess-0001","toolCall":{"toolCallId":"call-edit-2","title":"Edit notes.txt again","kind":"edit"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"reject","name":"Reject","kind":"reject_once"}]}}'
cancelled=
told=
while [ -z "$cancelled" ] || [ -z "$told" ]; do
  IFS= read -r line || exit 3
  case $line in
    *'"id":1,'*'"outcome":"cancelled"'*) [ -z "$cancelled" ] || exit 3; cancelled=1 ;;
    *'"method":"session/cancel"'*) [ -z "$told" ] || exit 3; told=1 ;;
    *) exit 3 ;;
  esac
done
say '{"jsonrpc":"2.0","id":"'"$prompt"'","result":{"stopReason":"cancelled"}}'
exit 0
"#

/-- The agent. -/
def agent : AgentsApi.Agent :=
  { name := "scripted", program := "/bin/sh", arguments := #["-c", script] }

/-- The command that runs the agent in `directory`. -/
def command (directory : String) : Editor.Process.Command :=
  agent.command directory

end AcpTest.ScriptedAgent
