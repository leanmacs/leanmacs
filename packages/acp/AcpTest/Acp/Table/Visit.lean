import Acp.Table.Visit
import AcpTest.Acp.Table.List

/-!
# Model tests: `Acp/Table/Visit.lean`

`visitChecks`: a visit shows a conversation's buffer, resumes a session no
conversation holds, retries one whose load was refused in its buffer, and
refuses a record that never opened a session. The test driver's root,
`AcpTest/Model.lean`, runs them.
-/

namespace AcpTest

open AgentsApi
open Acp.Table (Visit)

/-- The checks of what a visit does. -/
def visitChecks : List Check :=
  [{  name :=
        "a visit shows the buffer of a conversation of its id, resumes a session no conversation holds, retries a refused load in its buffer, and refuses a record that never opened"
      run := do
        let record := { agentRecord 1 with sessionId := some "sess-0001" }
        let held : Acp.Conversation :=
          { number := 1, agent := "claude-code", location := record.location, buffer := some 5
            session := some 1 }
        let refusedLoad :=
          { held with
            session := none, ended := some "the session did not resume" }
        let decided :=
          [Visit.decide record (some held), Visit.decide record none,
            Visit.decide record (some refusedLoad),
            Visit.decide record (some { held with buffer := none }),
            Visit.decide (agentRecord 2) none,
            Visit.decide (agentRecord 2)
              (some
                { held with
                  session := none, ended := some "x" })]
        saw
            (decided ==
              [.show 5, .resume "sess-0001" none, .resume "sess-0001" (some 5),
                .resume "sess-0001" none,
                .refuse "claude-code 2 never opened a session, so there is nothing to resume",
                .show 5])
            s!"{repr decided}" }]

end AcpTest
