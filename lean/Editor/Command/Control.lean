import Editor.Command.Call
import Editor.Completion.Candidate

/-!
# The loop's control of a running command

What a command asks the loop to do to its own program: end it, or put a
registered program before the rest of it. A `ControlRequest` is a request
of the editor's port (`EditorRequest.control`, `Editor/Command.lean`), and a
command asks it with `ControlRequest.ask` (`Editor/Api.lean`).

## The rules

- **Each request is the loop's to act on, by changing the command's
  program.** The transformation that runs a command
  (`Program.dispatched`, `Editor/Command/Dispatch.lean`) ends the program
  at `giveUp` and `breakOff`, and puts a registered program before the
  rest at `runCommand`, `askSource`, `askAtPoint` and `matchCandidates`.
- **A request names what it runs, and its reply is plain data**, so no
  request is answered a command: a command is a program over the port these
  requests are part of, and a reply that held one would be a type that
  refers to itself. A command that needs what the registry holds for a
  command's name has the loop run it (`runCommand`), with the call it
  hands it, which is plain data (`Editor/Command/Call.lean`).
- **The request itself is not guarded; the program it runs is.** What the
  loop puts before the rest is part of the asking command: its state
  requests are answered from the state the command had reached, its other
  requests are guarded, and what it did is rolled back with the command.
- **Where no loop dispatched the command, a runner answers it `bare`**
  (`ControlRequest.bare`): nothing is run and nothing is ended. Every
  command a host runs goes through the loop; only a test runs one bare.
- **A command is run inside the asking command by one request**,
  `runCommand`, with the name it is registered under and the call it is
  to be run with: the named command's program is put before the rest of
  the asking command's (`Editor/Command/Dispatch.lean`, "Requests that
  name something registered"). The reply says whether a command was
  registered under the name.
- **A completion source is asked inside the asking command by one
  request**, `askSource`, with the name it is registered under and the
  query (`Editor/Completion.lean`). It is the loop's to act on, as
  `runCommand` is: the source's program is put before the rest of the
  asking command's. The reply is what it answered, its candidates with its
  category and whether it filtered already (`Completion.Answer`), or
  `none` when no source is registered under the name. A source is a
  program over this port, so the request names it and the reply holds its
  candidates, which are plain data. Which sources a category has is a
  question to the registry (`RegistryRequest.categorySources`,
  `Editor/Command/Registry.lean`).
- **An at-point source's region is asked inside the asking command by one
  request**, `askAtPoint`, with the name it is registered under and the
  spot (`Editor/Completion/AtPoint.lean`), run as `askSource` is. Which
  at-point sources a buffer's chain has for an occasion is a question to
  the registry (`RegistryRequest.atPointSources`).
- **A text is matched with a category's completion style by one
  request**, `matchCandidates`, with the category, the text and the
  candidates' texts. The style the loop chooses for the category is run
  inside the asking command, over the fuzzy port, and the reply is its
  hits (`Completion.Hit`). A command that resolves a typed answer asks
  it, so the answer is resolved as the prompt of that category listed it.
  The request carries the category and the reply the hits, plain data, so
  no style crosses it.
- **A command gives up by one request**, `giveUp`, with its reason
  (`giveUp`, `Editor/Api.lean`): the loop ends the command's program at
  this request, with the reason (`Editor/Command/Dispatch.lean`, "A
  command that gives up").
- **A command breaks off by one request**, `breakOff`, with its reason
  (`breakOff`, `Editor/Api.lean`). It is the loop's to act on as `giveUp`
  is, and differs in what the loop then does: what the command did stays
  (`Editor/Command/Dispatch.lean`, "A command that breaks off").

It is a sub-port apart from the registry's questions
(`Editor/Command/Registry.lean`): a question is answered by a pure function
of what the loop was told, and changes neither the state nor the program,
while each request here changes the command's program, and `giveUp` and
`breakOff` ask the registry nothing.

## Where an addition goes

A new way to end the command, or to run something registered inside it, is
a constructor here with its `Reply` case and its `bare` case, its arm in
`Program.dispatched` (`Editor/Command/Dispatch.lean`), which the exhaustive
match there requires, and the operation in `Editor/Api.lean`.

Pinned by `ModelTest.controlRequestChecks` (the bare answers), and by the
dispatch checks named in `Editor/Command/Dispatch.lean`'s bullets
(`ModelTest.dispatchStateChecks`, `dispatchRunCommandChecks`,
`dispatchGiveUpChecks`, `dispatchCommandGivesUpChecks` and
`dispatchCommandBreaksOffChecks`).
-/

namespace Editor

/-- What a command may ask the loop to do to its own program: end it, or run
something registered inside it. -/
inductive ControlRequest where
  /-- Run the command registered under `name` inside this command, with
  `call`. -/
  | runCommand (name : String) (call : Call)
  /-- Ask the completion source registered under `name` for its candidates
  for `query`, inside this command. -/
  | askSource (name : String) (query : Completion.Query)
  /-- Ask the at-point source registered under `name` for its region at
  `spot`, inside this command. -/
  | askAtPoint (name : String) (spot : Completion.Spot)
  /-- Which of `candidates` `text` matches, in order, with the completion
  style the loop chooses for `category` (`none` for a prompt with no
  category), as the prompt of that category lists them. -/
  | matchCandidates (category : Option String) (text : String) (candidates : Array String)
  /-- End this command here, with `reason`: it gives up. -/
  | giveUp (reason : String)
  /-- End this command here, with `reason`, and keep what it did: it breaks
  off. -/
  | breakOff (reason : String)

/-- The type of the reply to each request. -/
abbrev ControlRequest.Reply : ControlRequest → Type
  | .runCommand .. => Bool
  | .askSource .. => Option Completion.Answer
  | .askAtPoint .. => Option Completion.Region
  | .matchCandidates .. => Array Completion.Hit
  | .giveUp _ => Unit
  | .breakOff _ => Unit

/-- The answer to `request` where no loop dispatched the command: nothing
is run and nothing is ended. -/
def ControlRequest.bare : (request : ControlRequest) → request.Reply
  | .runCommand .. => false
  | .askSource .. => none
  | .askAtPoint .. => none
  | .matchCandidates .. => #[]
  | .giveUp _ => ()
  | .breakOff _ => ()

end Editor
