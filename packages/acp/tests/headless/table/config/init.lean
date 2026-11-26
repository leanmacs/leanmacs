import Editor
import AgentsApi
open Editor

-- The agent table's CLI fixture pair (`table/script`, then
-- `table-restore/script`): `claude-code` is a scripted agent, registered
-- after acp's and so in its place, never the user's real adapter. It is a
-- POSIX `sh` script run as `/bin/sh -c`, as acp's linked test's scripted
-- agent is (`AcpTest.ScriptedAgent`). It answers `initialize` with
-- `loadSession`, then:
--
-- - on `session/new`, the session `sess-0001`, and exits 0 at once, so the
--   session's one batch after its open is its end, and the session job
--   ends without a pause the CLI's clock would have to be moved past;
-- - on `session/load` of `sess-0001`, the history replayed, the user's
--   `Tidy the notes.`, the reply `Tidied.` and the title `Tidy the notes`,
--   then its answer, so the history is held before the open completes and
--   is the session's first batch; then it waits for the end of its input,
--   exiting 0, and exits 3 on any line, as `agent-stop` ends it;
-- - on anything else, exits 3.
--
-- Every value is a placeholder.

/-- The scripted agent's script. -/
def script : String :=
  r#"IFS= read -r line || exit 3
case $line in *'"method":"initialize"'*) ;; *) exit 3 ;; esac
id=${line#*\"id\":\"}; id=${id%%\"*}
printf '%s\n' '{"jsonrpc":"2.0","id":"'"$id"'","result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true},"authMethods":[]}}'
IFS= read -r line || exit 3
id=${line#*\"id\":\"}; id=${id%%\"*}
case $line in
  *'"method":"session/new"'*)
    printf '%s\n' '{"jsonrpc":"2.0","id":"'"$id"'","result":{"sessionId":"sess-0001"}}'
    exit 0 ;;
  *'"method":"session/load"'*'"sessionId":"sess-0001"'*)
    printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-0001","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Tidy the notes."},"messageId":"msg-u1"}}}'
    printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-0001","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Tidied."},"messageId":"msg-1"}}}'
    printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-0001","update":{"sessionUpdate":"session_info_update","title":"Tidy the notes"}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":"'"$id"'","result":{}}'
    while IFS= read -r line; do exit 3; done
    exit 0 ;;
  *) exit 3 ;;
esac
"#

def setup : SetupM Unit :=
  Extension.add ({ name := "claude-code", program := "/bin/sh", arguments := #["-c", script] } : AgentsApi.Agent)
