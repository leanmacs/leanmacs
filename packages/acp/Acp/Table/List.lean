import Acp.Conversation.Render
import AgentsApi.Table
import AgentsApi.View

/-!
# A project's agents list, as text

The text of a project's agents list, pure (`Acp.Table.render`): the header
`agents of <project>`, then `<k> sessions`, `1 session` or `no sessions`,
an empty row, then each session of the project's agent table in the list's
order (`AgentsApi.Table.ordered`: by attention, then by id), as the chosen
view lists it (`ConversationView.listed`). Every line a view gives is split
at its line feeds, as a conversation's are, so a view cannot break the map
of rows. With the lines comes that map: for each row, the id of the agent
it shows, which `agent-visit` reads to find the agent on the cursor's row
(`rowOf` gives an agent's first row).
-/

namespace Acp.Table

open AgentsApi

/-- The list's header: its project, how many sessions, and an empty row. -/
def header (project : String) (count : Nat) : Array String :=
  let counted :=
    match count with
    | 0 => "no sessions"
    | 1 => "1 session"
    | count => s!"{count} sessions"
  #[s!"agents of {project}", counted, ""]

/-- The text of the agents list of `project` as `view` lists `records`, a
line a row, `running` saying whether a session of an id runs, and for each
row the id of the agent it shows, if any (the module docs). -/
def render (view : ConversationView) (project : String) (records : Array AgentRecord)
    (running : Nat → Bool) : Array String × Array (Option Nat) :=
  Id.run do
    let top := header project records.size
    let mut lines := top
    let mut map : Array (Option Nat) := top.map fun _ => none
    for record in Table.ordered records do
      let shown := Acp.Conversation.rows (view.listed record (running record.id))
      lines := lines ++ shown
      map := map ++ shown.map fun _ => some record.id
    return (lines, map)

/-- The text of the list: each row ended with a line feed. -/
def text (view : ConversationView) (project : String) (records : Array AgentRecord)
    (running : Nat → Bool) : String :=
  String.join ((render view project records running).1.toList.map (· ++ "\n"))

/-- The first row that shows the agent `id`, if one does. -/
def rowOf (view : ConversationView) (project : String) (records : Array AgentRecord)
    (running : Nat → Bool) (id : Nat) : Option Nat :=
  (render view project records running).2.findIdx? (· == some id)

end Acp.Table
