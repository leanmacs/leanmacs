import Acp.Service
import AcpTest.Check

/-!
# Model tests: `Acp/Service.lean`

`serviceChecks`: the service `agents` over a binding written in the test,
which records each call and answers from a table: each request of
`agents-api`'s vocabulary reaches the binding's own call with its
arguments, the MCP servers as the crate reads them; a request of another
service is not taken; and a reply is read back as the request's own type,
or refused. The test driver's root, `AcpTest/Model.lean`, runs them.
-/

namespace AcpTest

open AgentsApi

/-- A binding that records each call it is handed and takes every request,
its replies read from `replies`. -/
def recording (calls : IO.Ref (Array String)) (replies : List (UInt64 × String)) : Acp.Binding where
  «open» request child cwd servers := do
    calls.modify (·.push s!"open {request} {child} {cwd} {repr servers}")
    return true
  next request session := do
    calls.modify (·.push s!"next {request} {session}")
    return true
  prompt request session text := do
    calls.modify (·.push s!"prompt {request} {session} {text}")
    return true
  cancelTurn request session := do
    calls.modify (·.push s!"cancel {request} {session}")
    return true
  setMode request session mode := do
    calls.modify (·.push s!"setMode {request} {session} {mode}")
    return true
  answer request session ticket option := do
    calls.modify (·.push s!"answer {request} {session} {ticket} {option}")
    return true
  take request := return (replies.find? (·.1 == request)).map (·.2)
  withdraw request := do
    calls.modify (·.push s!"withdraw {request}")
    return true
  flush request := calls.modify (·.push s!"flush {request}")

/-- The checks of the service over a binding. -/
def serviceChecks : List Check :=
  [{  name :=
        "each request of agents-api's vocabulary reaches the binding's own call with its arguments, and a request of another service is not taken"
      run := do
        let calls ← IO.mkRef #[]
        let service := Acp.jobService (recording calls [])
        let requests : List Request :=
          [.open 7 "/work/example" #[{ name := "s", command := "c" }], .next 1,
            .send 1 (.prompt "ask"), .send 1 .cancel, .send 1 (.setMode "mode-auto"),
            .send 1 (.answer 2 "allow")]
        let mut taken := true
        for (request, id) in requests.zip (List.range requests.length) do
          taken := taken && (← service.start id.toUInt64 request.toPackage)
        let other ← service.start 9 { service := "echo", operation := "say" }
        service.cancel 3
        service.flush 4
        let seen ← calls.get
        saw
            (taken && !other &&
              seen ==
                #["open 0 7 /work/example \"server\\tname=s\\tcommand=c\"", "next 1 1",
                  "prompt 2 1 ask", "cancel 3 1", "setMode 4 1 mode-auto", "answer 5 1 2 allow",
                  "withdraw 3", "flush 4"])
            s!"{seen}" },
    { name :=
        "a reply is read back as the request's own type; the crate's refusal, text that does not read and no reply at all are refused"
      run := do
        let calls ← IO.mkRef #[]
        let service :=
          Acp.jobService
            (recording calls
              [(1, "sent\tturn=1"), (2, "refused\treason=the session 1 has ended"),
                (3, "sent\tturn=x")])
        let request := (Request.send 1 (.prompt "ask")).toPackage
        let sent ← service.take 1 request
        let refused ← service.take 2 request
        let garbled ← service.take 3 request
        let missing ← service.take 4 request
        let turn :=
          match sent with
          | .ok value => (value.get? Sent).bind (·.turn)
          | .error _ => none
        let reason (reply : Editor.PackageReply) : Option String :=
          match reply with
          | .error (.refused reason) => some reason
          | _ => none
        saw
            (turn == some 1 && reason refused == some "the session 1 has ended" &&
              (reason garbled).isSome &&
              (reason missing).isSome)
            s!"turn {turn}, refused {reason refused}, garbled {reason garbled}, missing {reason missing}" }]

end AcpTest
