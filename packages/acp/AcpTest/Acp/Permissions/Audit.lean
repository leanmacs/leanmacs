import Acp.Codec
import Acp.Permissions.Audit
import AcpTest.Acp.Permissions.Policy

/-!
# Model tests: `Acp/Permissions/Audit.lean`

`auditChecks`: the audit log's records as lines, each held as a golden
literal; a tab and a line feed in a field escaped, so a record is one line,
and read back by `Acp.Codec.split`; a batch's records in event order, each
request's `decided` right after its `asked`; and a `closed` record for each
ticket still pending when a conversation ends. The test driver's root,
`AcpTest/Model.lean`, runs them.
-/

namespace AcpTest

open AgentsApi
open AgentsApiTest
open Acp.Permissions

/-- The request of `askedBatch`, as `openedExample` asks it. -/
def askedRequest : PermissionRequest :=
  { agent := Acp.defaultAgent, root := "/work/example", sessionId := Contract.sessionId
    ticket := 1, turn := some 1, call := Fake.editAsked, options := Fake.adapterOptions }

/-- The golden `asked` line of `askedRequest` in the project `example`. -/
def askedLine : String :=
  "asked\tproject=example\troot=/work/example\tagent=claude-code\tsession=sess-0001\tconversation=1\tticket=1\tturn=1\ttitle=Edit notes.txt\tkind=edit\tinput={\"file_path\":\"/work/example/notes.txt\",\"old_string\":\"beta\",\"new_string\":\"gamma\"}\tdiff=/work/example/notes.txt\told=beta\tnew=gamma\toption=allow-once\toptionKind=allow_once\toptionName=Yes\toption=allow-session\toptionKind=allow_always\toptionName=Yes, for this session\toption=reject\toptionKind=reject_once\toptionName=No"

/-- Each record and its golden line. -/
def goldenRecords : List (Record × String) :=
  [(.asked "example" 1 askedRequest, askedLine),
    (.decided 1 1 "default" none,
      "decided\tconversation=1\tticket=1\tpolicy=default\tdecision=ask"),
    (.decided 1 1 "default" (some "allow-once"),
      "decided\tconversation=1\tticket=1\tpolicy=default\tdecision=allow-once"),
    (.answered 1 1 "allow-once" .user,
      "answered\tconversation=1\tticket=1\toption=allow-once\tby=user"),
    (.answered 2 1 "allow-once" .policy,
      "answered\tconversation=2\tticket=1\toption=allow-once\tby=policy"),
    (.refused 1 1 "allow-once" .user "refused: the ticket 1 is not parked",
      "refused\tconversation=1\tticket=1\toption=allow-once\tby=user\treason=refused: the ticket 1 is not parked"),
    (.withdrawn 1 1, "withdrawn\tconversation=1\tticket=1"),
    (.closed 1 1 "session stopped", "closed\tconversation=1\tticket=1\treason=session stopped")]

/-- The checks of `Acp/Permissions/Audit.lean`. -/
def auditChecks : List Check :=
  [{  name := "each record of the audit log is its golden line"
      run := do
        let wrong := goldenRecords.filter fun (record, line) => record.line != line
        saw wrong.isEmpty s!"{wrong.map fun (record, _) => record.line}" },
    { name :=
        "a tab and a line feed in a field are escaped, so a record is one line, and Acp.Codec.split reads it back; a new file's diff has no old text and a text item is its text"
      run := do
        let call :=
          { Fake.editAsked with
            rawInput := "a\tb\nc",
            content := #[.text "x\ny", .diff "/work/example/new.txt" none "z"] }
        let line :=
          (Record.asked "example" 1
              { askedRequest with
                call, turn := none }).line
        let read := Acp.Codec.split line
        let field (name : String) :=
          match read with
          | .ok (_, fields) => (fields.find? (·.1 == name)).map (·.2)
          | .error _ => none
        let names :=
          match read with
          | .ok (kind, fields) => kind :: fields.map Prod.fst
          | .error _ => []
        saw
            (!line.contains '\n' && field "input" == some "a\tb\nc" &&
              field "text" == some "x\ny" &&
              field "diff" == some "/work/example/new.txt" &&
              field "old" == none &&
              field "turn" == none &&
              names.take 8 ==
                ["asked", "project", "root", "agent", "session", "conversation", "ticket", "title"])
            s!"{repr line}" },
    { name :=
        "a batch's records are in event order: each request's asked, then its decision, and a withdrawal's withdrawn, with no decision for a request withdrawn in the batch"
      run := do
        let batch :=
          {
            events :=
              askedBatch.events ++
                #[.permission 2 (some 1) Fake.editAsked Fake.adapterOptions, .withdrawn 2] }
        let after := openedExample.applyBatch batch
        let made := decisions PermissionPolicy.ask after batch
        let records := recordsOf "example" after batch PermissionPolicy.defaultName made
        saw
            (records ==
              #[.asked "example" 1 askedRequest, .decided 1 1 "default" none,
                .asked "example" 1 { askedRequest with ticket := 2 }, .withdrawn 1 2])
            s!"{records.map (·.line)}" },
    { name := "a conversation that ends closes each ticket still pending, and none other"
      run := do
        let after :=
          (openedExample.applyBatch
                {
                  events :=
                    askedBatch.events ++
                      #[.permission 2 (some 1) Fake.editAsked Fake.adapterOptions,
                        .permission 3 (some 1) Fake.editAsked Fake.adapterOptions,
                        .withdrawn 3] }).answered
            1 "allow-once"
        let records := closedRecords after "session stopped"
        saw (records == #[.closed 1 2 "session stopped"]) s!"{records.map (·.line)}" }]

end AcpTest
