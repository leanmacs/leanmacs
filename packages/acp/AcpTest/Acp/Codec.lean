import Acp.Codec
import AcpTest.Check

/-!
# Model tests: `Acp/Codec.lean`

`codecChecks`: the golden lines of the crate's encoding, the same literals
as `rust/src/event.rs`'s tests, decoded into `agents-api`'s events and
replies; a line that does not decode refused, never a panic; the replies
read back as the request they answer; and the MCP servers written as the
crate's `servers_of` reads them. The test driver's root,
`AcpTest/Model.lean`, runs them.
-/

namespace AcpTest

open AgentsApi
open Acp.Codec

/-- A call with every kind of field, an escape in its title: `event.rs`'s
`call()`. -/
def goldenCall : ToolCall :=
  { id := "call-edit-1", title := "Edit\tnotes.txt", kind := "edit", status := "pending"
    locations := #[("/work/example/notes.txt", none), ("/work/example/b.txt", some 3)]
    content :=
      #[.text "line one\nline two", .diff "/work/example/notes.txt" (some "a\\b") "c\r\n",
        .diff "/work/example/new.txt" none "fresh"]
    rawInput := "{\"path\":\"/work/example/notes.txt\"}" }

/-- The golden lines and the events they decode to: the same literals as
`event.rs`'s `each_event_encodes_to_its_golden_line`. -/
def goldenEvents : List (String × Event) :=
  [("chunk\tmessage=msg-1\ttext=Done.", .chunk (some "msg-1") "Done."),
    ("chunk\ttext=a\\tb", .chunk none "a\tb"),
    ("toolCall\tid=call-edit-1\ttitle=Edit\\tnotes.txt\tkind=edit\tstatus=pending\tlocation.path=/work/example/notes.txt\tlocation.path=/work/example/b.txt\tlocation.line=3\tcontent.text=line one\\nline two\tdiff.path=/work/example/notes.txt\tdiff.old=a\\\\b\tdiff.new=c\\r\\n\tdiff.path=/work/example/new.txt\tdiff.new=fresh\trawInput={\"path\":\"/work/example/notes.txt\"}",
      .toolCall goldenCall),
    ("permission\tticket=1\tturn=1\tid=call-2\ttitle=\tkind=other\tstatus=pending\trawInput=\toption.id=allow-once\toption.name=Allow\toption.kind=allow_once",
      .permission 1 (some 1) { id := "call-2" }
        #[{ id := "allow-once", name := "Allow", kind := "allow_once" }]),
    ("withdrawn\tticket=2", .withdrawn 2),
    ("usage\tused=1200\tsize=200000", .usage 1200 200000 none),
    ("usage\tused=1300\tsize=200000\tcost.amount=0.0123\tcost.currency=USD",
      .usage 1300 200000 (some ("0.0123", "USD"))),
    ("title\ttext=Example title", .title "Example title"),
    ("mode\tid=mode-auto", .mode "mode-auto"),
    ("turnEnded\tturn=1\tstopReason=end_turn", .turnEnded 1 "end_turn"),
    ("ended\thow=exited\tcode=0", .ended (.exited 0)),
    ("ended\thow=signalled\tsignal=9", .ended (.signalled 9)),
    ("ended\thow=lineTooLong", .ended .lineTooLong),
    ("ended\thow=failed\twords=gone", .ended (.failed "gone")),
    ("ended\thow=protocolError\twords=bad", .ended (.protocolError "bad"))]

/-- The golden `opened` line, `event.rs`'s `each_reply_encodes_to_its_golden_line`. -/
def goldenOpened : String :=
  "opened\tsession=1\tsessionId=sess-0001\tmode=mode-ask\tmode.id=mode-ask\tmode.name=Ask\tmode.description=Asks first\tmode.id=mode-auto\tmode.name=Auto"

/-- The reason of `reply`, if it is a refusal. -/
def refusalOf (reply : Editor.PackageReply) : Option String :=
  match reply with
  | .error (.refused reason) => some reason
  | _ => none

/-- Whether `reply` is a refusal. -/
def isRefused (reply : Editor.PackageReply) : Bool :=
  match reply with
  | .error (.refused _) => true
  | _ => false

/-- The checks of the codec. -/
def codecChecks : List Check :=
  [{  name :=
        "each golden line of the crate's encoding decodes to its event, escapes undone, lists in order, optional fields absent"
      run := do
        let wrong := goldenEvents.filter fun (line, event) => (event? line).toOption != some event
        saw wrong.isEmpty s!"{wrong.map fun (line, _) => (line, repr (event? line))}" },
    { name :=
        "the golden opened, sent and refused lines decode to the session, the turn and the reason, and a batch's lines to its events"
      run := do
        let opened := opened? goldenOpened
        let batch := batch? "withdrawn\tticket=2\ntitle\ttext=t"
        saw
            (opened.toOption ==
                some
                  { session := 1, sessionId := "sess-0001", mode := some "mode-ask"
                    modes :=
                      #[{ id := "mode-ask", name := "Ask", description := some "Asks first" },
                        { id := "mode-auto", name := "Auto" }] } &&
              (sent? "sent\tturn=2").toOption == some { turn := some 2 } &&
              (sent? "sent").toOption == some {} &&
              refusal? "refused\treason=no\\nsuch" == some "no\nsuch" &&
              batch.toOption == some { events := #[.withdrawn 2, .title "t"] })
            s!"opened {repr opened}, batch {repr batch}" },
    { name :=
        "a line that does not decode is refused, never a panic: a bad escape, an unknown kind, a missing field, a field out of order, an extra field, a number that is not one, an empty batch"
      run := do
        let bad :=
          ["chunk\ttext=a\\qb", "shout\ttext=a", "turnEnded\tturn=1",
            "turnEnded\tstopReason=x\tturn=1", "withdrawn\tticket=2\textra=1",
            "withdrawn\tticket=two", "ended\thow=sideways", "chunk\ttext"]
        let decoded := bad.map event?
        saw (decoded.all (·.toOption.isNone) && (batch? "").toOption.isNone)
            s!"{decoded.map (·.toOption.isSome)}" },
    { name :=
        "a reply reads back as the request it answers: open's session, next's batch, send's turn, a refusal's reason, and a line of another kind refused"
      run := do
        let openedReply := reply (.open 3 "/w" #[]) goldenOpened
        let nextReply := reply (.next 1) "withdrawn\tticket=2"
        let sentReply := reply (.send 1 (.prompt "ask")) "sent\tturn=1"
        let refused :=
          reply (.send 1 (.answer 9 "allow")) "refused\treason=the ticket 9 is not parked"
        let crossed := reply (.next 1) goldenOpened
        let held :=
          (match openedReply with
            | .ok value => (value.get? Opened).map (·.session) == some 1
            | .error _ => false) &&
            (match nextReply with
            | .ok value => (value.get? Batch) == some { events := #[.withdrawn 2] }
            | .error _ => false) &&
            (match sentReply with
            | .ok value => (value.get? Sent) == some { turn := some 1 }
            | .error _ => false) &&
            refusalOf refused == some "the ticket 9 is not parked" &&
            isRefused crossed
        saw held s!"crossed {isRefused crossed}" },
    { name := "the MCP servers are written one a line as the crate reads them, their values escaped"
      run := do
        let text :=
          serversText
            #[{ name := "example-server", command := "/usr/local/bin/example"
                arguments := #["--a", "b\tc"], environment := #[("KEY", "va\nlue")] },
              { name := "bare", command := "bare" }]
        saw
            (text ==
              "server\tname=example-server\tcommand=/usr/local/bin/example\targ=--a\targ=b\\tc\tenv.name=KEY\tenv.value=va\\nlue\nserver\tname=bare\tcommand=bare")
            s!"{repr text}" }]

end AcpTest
