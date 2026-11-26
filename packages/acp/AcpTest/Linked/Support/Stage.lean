import Acp.ClaudeCode
import Acp.Conversation
import Acp.Permissions
import AcpTest.Check
import AgentsApiTest.Fake
import BuffersApiTest.Fake
import Editor.Api
import Editor.File.Model
import Editor.Jumps
import Editor.Process.Model
import Editor.Test.Ex
import Editor.Test.Linked.Host
import Editor.Test.Linked.Keys
import Editor.Test.Minibuffer
import Editor.Test.Workspace
import FilesApiTest.Fake

/-!
# Linked tests' support: the stepped stage of a conversation

What the linked checks of `Acp/Conversation.lean` and `Acp/Permissions.lean`
share (`AcpTest/Linked/Acp/Conversation.lean`,
`AcpTest/Linked/Acp/Permissions.lean`): a host stepped on the check's thread
over a stepped stage whose service `agents` is `agents-api`'s fake and whose
agent's child is the stage's process fake, paused for ever
(`withConversation`); the packages it is handed (`stagePackages`), the
check's own package among them (`probePackage`); and the helpers a check
types, steps and reads the scene with.

The stage's host is handed the core's test kit's ex line, minibuffer and
attach stand-in (a buffer that takes in a file gets the workspace at
`/work/example`), `files-api`'s fake, `buffers-api`'s fake (whose
`close-buffer` runs the hook `BuffersApi.Closing`), then the packages the
root hands in, `acp`'s, with its crate's service dropped (a stepped
stage's package services are its fakes), then a check's own extra packages,
then the check's own package (`probePackage`). It imports no implementation
package.
-/

namespace AcpTest.Linked

open Editor
open Editor.Test
open Editor.Test.Linked
open AgentsApi
open AgentsApiTest

/-- The workspace's root. -/
def root : String :=
  "/work/example"

/-- The file each check opens: a marker of the workspace. -/
def opened : String :=
  "/work/example/lakefile.lean"

/-- The prompt each check types. -/
def promptText : String :=
  "Read notes.txt."

/-- The agent's child, as the stage's process fake runs it: exactly the
command the session job starts, paused for ever, as an agent lives until it
is ended. -/
def agentChild : Process.StreamScript :=
  { command := Acp.claudeCode.command root, steps := #[.pause 1000000000] }

/-- The name of the check's command that puts the focused view's cursor on
the first row of the tool call `call-edit-1`. -/
def cursorToCall : String :=
  "test-cursor-to-call"

/-- The name of the check's command that says, in the echo area, what the
focused buffer's conversation holds. -/
def probeName : String :=
  "test-probe"

/-- The name of the check's command that says, in the echo area, the
number of every conversation in acp's store. -/
def storeName : String :=
  "test-store"

/-- The name of the check's command that gives the focused buffer a
workspace on another machine, where commands cannot run. -/
def toReachable : String :=
  "test-to-reachable"

/-- The workspace `test-to-reachable` gives: a pod's `/app`, which a command
would reach through `kube`. -/
def reachable : Location :=
  .reachable "kube" "pod" "/app"

/-- The name of the check's command that puts the focused view's cursor on
the first row of a request in the permission queue the view shows: the
words name its conversation and its ticket. -/
def cursorToRequest : String :=
  "test-cursor-to-request"

/-- The name of the check's command that says, in the echo area, the text
of the conversation its words name, as acp's store holds it, whatever view
shows it: each row, ` | ` between two. -/
def conversationProbe : String :=
  "test-probe-conversation"

/-- The name of the check's command that says, in the echo area, whether
the focused buffer is read-only. -/
def readOnlyProbe : String :=
  "test-read-only"

/-- The name of the check's command that shows the buffer of the
conversation its words name in the focused view. -/
def showConversation : String :=
  "test-show-conversation"

/-- The words of a command's text argument, split at spaces. -/
def wordsOf (call : Call) : List String :=
  match call.arguments with
  | .str text :: _ => (text.splitOn " ").filter fun (word : String) => !word.isEmpty
  | _ => []

/-- The check's own package: `test-cursor-to-call`, which reads the
conversation from acp's store and the call's row from its render
(`Acp.Conversation.rowOf`), and places the cursor there as compile places
its followers; `test-cursor-to-request <conversation> <ticket>`, which reads
the focused queue's entries from acp's store and the request's row from its
render (`Acp.Permissions.rowOf`), and places the cursor there likewise;
`test-probe`, which says the pending tickets, the turn in flight and
whether the buffer is read-only; `test-probe-conversation <n>`, which says
the text of the conversation `n` as acp's store holds it, so a check reads a
conversation that no view shows and tells two conversations of one header
apart; `test-show-conversation <n>`, which shows the buffer of the conversation
`n` in the focused view; `test-read-only`, which says whether the focused
buffer is read-only; `test-store`, which says the number of every conversation in the
store and of every queue buffer in acp's queue store; and `test-to-reachable`, which gives the focused buffer a workspace
where commands cannot run. -/
def probePackage : Package :=
  { name := "acp-test"
    setup := do
      commandWith cursorToRequest fun call => do
          let some [conversation, ticket] := (wordsOf call).mapM String.toNat? | return
          let some (project, entries) ← Acp.Permissions.queueOf? call.target.window.buffer | return
          let view ← Acp.Conversation.chosenView
          let some row := Acp.Permissions.rowOf view project entries conversation ticket | return
          let offset ← call.target.buffer.text.offsetOf ⟨row, 0⟩
          Jumps.placeCursor call.target.window.id offset
      exCommand cursorToRequest cursorToRequest (takes := .text)
      commandWith conversationProbe fun call => do
          let some [number] := (wordsOf call).mapM String.toNat? | message "conversation: none"
          let some conversation ←
            Acp.Conversation.conversation? number | message "conversation: none"
          let text := (Acp.Conversation.render (← Acp.Conversation.chosenView) conversation).1
          message s!"conversation: {" | ".intercalate text.toList}"
      exCommand conversationProbe conversationProbe (takes := .text)
      commandWith showConversation fun call => do
          let some [number] := (wordsOf call).mapM String.toNat? | return
          let some conversation ← Acp.Conversation.conversation? number | return
          let some index := conversation.buffer | return
          discard <| call.target.window.id.show ⟨index⟩
      exCommand showConversation showConversation (takes := .text)
      commandWith readOnlyProbe fun call => do
          let readOnly := ((← editorState).buffer? call.target.window.buffer).any (·.readOnly)
          message s!"read-only {readOnly}"
      commandWith cursorToCall fun call => do
          let some conversation ← Acp.Conversation.ofBuffer? call.target.window.buffer | return
          let view ← Acp.Conversation.chosenView
          let some row := Acp.Conversation.rowOf view conversation "call-edit-1" | return
          let offset ← call.target.buffer.text.offsetOf ⟨row, 0⟩
          Jumps.placeCursor call.target.window.id offset
      commandWith probeName fun call => do
          let some conversation ←
            Acp.Conversation.ofBuffer? call.target.window.buffer | message "probe: none"
          let readOnly := ((← editorState).buffer? call.target.window.buffer).any (·.readOnly)
          message
              s!"probe: pending {conversation.pending.toList}, turn {conversation.turn}, read-only {readOnly}"
      commandWith storeName fun _ => do
          message
              s!"store: {((← Acp.Conversation.conversations).map (·.number)).toList}, queues {(← Acp.Permissions.queueBuffers).toList}"
      commandWith toReachable fun call => do
          discard <| Workspace.register reachable "git@example.invalid:o/r.git"
          Workspace.setBufferWorkspace call.target.window.buffer reachable }

/-- The packages a stage's host is handed (the module docs): `extra` after
`packages`. -/
def stagePackages (packages : Array Package) (extra : Array Package := #[]) : Array Package :=
  #[exLinePackage, Minibuffer.package, FilesApiTest.fake, BuffersApiTest.fake,
      attachPackage (Workspace.Found.ofMarker root)] ++
    packages.map (fun package => { package with services := #[] }) ++
    extra ++
    #[probePackage]

/-- The file fake's model: `/work/example` holding an empty
`lakefile.lean`. -/
def files : FileModel :=
  ((({} : FileModel).withDirectory "/").withDirectory "/work").withDirectory root |>.withFile opened
    .empty

/-- Runs `check` against a host stepped on the check's thread over a stepped
stage of `context`'s elaborator with no config, handed `stagePackages
packages extra`, whose service `agents` is a fake over `script` and whose
agent's child is `agentChild`. With `state`, the host has that state
directory, its session journal the recording fake
(`Stage.recordingJournal`), and the file fake's model holds the directory,
so nothing real is written. `check` is handed the session, the fake and the
stage's fakes. -/
def withConversation (context : HostContext) (packages : Array Package) (script : Fake.Script)
    (check : Session → Fake → Stage.Fakes → IO Bool) (state : Option System.FilePath := none)
    (extra : Array Package := #[]) : IO Bool := do
  let fake ← Fake.new script
  let stage ←
    Stage.new context context.elaborator (memorySource [])
        { packages := stagePackages packages extra }
  let model := (state.map files.withDirectory).getD files
  let stage ← stage.stepped model { streams := #[agentChild] } (packageFakes := #[fake.packageFake])
  let stage ←
    match state with
    | some directory =>
      pure (← stage.recordingJournal directory).1
    | none =>
      pure stage
  let some fakes := stage.fakes | return false
  onStage stage fun drive stage => check (Session.ofStage drive "/" stage) fake fakes

/-- Types `line` on the kit's ex line: the command `ex` asks, `line` is
committed into the minibuffer and the accept key pressed. Sends the
requests and waits for nothing. -/
def sendEx (session : Session) (line : String) : IO Unit := do
  session.send (.run ExLine.name)
  session.commit line
  for key in acceptKeys do
    session.press key

/-- Types `line` on the kit's ex line, drains the host's queue, and steps
the session to rest. -/
def exStepped (session : Session) (line : String) : IO Bool := do
  sendEx session line
  unless ← session.handled do
    return false
  session.step
  return true

/-- The text a quoted string of a scene line holds, from the quote at its
start to the one that ends it, and what follows; none when it is no quoted
string. -/
partial def unquote? (chars : List Char) (done : String := "") : Option (String × List Char) :=
  match chars with
  | '"' :: rest => some (done, rest)
  | '\\' :: 'n' :: rest => unquote? rest (done.push '\n')
  | '\\' :: 't' :: rest => unquote? rest (done.push '\t')
  | '\\' :: 'r' :: rest => unquote? rest (done.push '\r')
  | '\\' :: c :: rest => unquote? rest (done.push c)
  | c :: rest => unquote? rest (done.push c)
  | [] => none

/-- The text the scene shows in a view of a buffer, a line a row: the first
view whose text starts with `start`. -/
def bufferLines (session : Session) (start : String) : IO (Array String) := do
  for line in ← session.sceneLines do
    if line.startsWith "view " then
      match (line.splitOn ": \"").drop 1 with
      | [] =>
        pure ()
      | parts =>
        if let some (text, _) := unquote? (": \"".intercalate parts).toList then
          if text.startsWith start then
            return ((text.splitOn "\n").toArray.popWhile (·.isEmpty))
  return #[]

/-- The text the scene shows in a view of the conversation buffer, a line a
row: the first view whose text starts as a conversation's header does. -/
def conversationLines (session : Session) : IO (Array String) :=
  bufferLines session s!"{Acp.defaultAgent} in "

/-- Opens the marker file, starts a session and steps to rest: the session
open and its job parked on `next`. -/
def started (session : Session) : IO Bool := do
  session.ask [.reload]
  session.ask [.open opened]
  session.step
  exStepped session Acp.Conversation.startName

/-- The check's thread's requests, as the fake logged them. -/
def onThread (fake : Fake) : IO Bool := do
  let thread ← IO.getTID
  return (← fake.log).all (·.2.2 == thread)

/-- Whether the trace of the fake's session replays on the protocol's model
with no violation. -/
def replays (fake : Fake) : IO Bool := do
  return (Protocol.replay (← fake.trace)).toOption.isSome

/-- Stops the session (`agent-stop`) and steps to rest, so the check leaves
no job running. -/
def stopped (session : Session) : IO Bool :=
  exStepped session Acp.Conversation.stopName

/-- The echo area's text after `test-probe`. -/
def probe (session : Session) : IO String := do
  session.ask [.run probeName]
  session.echo

/-- Every piece of the stage's fakes' work that can run, run, and no host
queue drained: whether any ran. -/
def stepFakes (fakes : Stage.Fakes) : IO Bool := do
  let mut ran := false
  while ← fakes.stepWork do
    ran := true
  return ran

/-- The order the session's requests carried, as a check reads the fake's
log. -/
def ordersOf (fake : Fake) : IO (Array Order) := do
  return (← fake.log).filterMap fun (request, _, _) =>
      match request with
      | .send _ order => some order
      | _ => none

/-- Whether the echo area's text `echo` says `text`. -/
def says (echo text : String) : Bool :=
  (echo.splitOn text).length > 1

/-- Types `line` on the kit's ex line, steps the session to rest, and returns
what the echo area then says. -/
def echoAfter (session : Session) (line : String) : IO String := do
  unless ← exStepped session line do
    return "the ex line was not handled"
  session.echo

/-- The echo area's text after `test-store`. -/
def storeProbe (session : Session) : IO String := do
  session.ask [.run storeName]
  session.echo

end AcpTest.Linked
