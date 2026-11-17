import Editor.Command
import Editor.Completion.Candidate

/-!
# Completion sources

What supplies the candidates of a prompt (`prompt`, `Editor/Api.lean`,
"Prompts"): a source. It is an interface like the editor's ports, with a
pure model (`Source.fixed`), a fake for tests
(`Editor/Completion/Fake.lean`) and a contract every source is held to
(`Editor/Completion/Contract.lean`).

## A source

- **A name**, which it is registered under and which a prompt may ask it
  by, and which is the group its candidates are listed under unless a
  candidate names its own (`Candidate.inGroup`).
- **A category**, a word for what it lists (`buffer`, `ex-line`). Nothing
  reads it yet: a prompt that asks by category is a later phase's.
- **A function from a query to candidates** (`Query`, `Candidate`,
  `Editor/Completion/Candidate.lean`): a program over the editor's port,
  so it may ask what a command may, the state and a text, and has no `IO`
  and cannot wait. It reads and does not write: that is the contract.

It answers now, inside the command that asks. A source that answers later,
from a job, is a later phase's.

## Asking one

A prompt is asked with a list of `SourceRef`s: a source given as a value,
or one named, which the loop that runs the asking command looks up among
the registered sources (`StateRequest.askSource`,
`Editor/Command/Dispatch.lean`). A source is a program over the port a
request is part of, so a request cannot hold one, nor a reply: the name
crosses, and the loop runs the source it stands for inside the asking
command, as it runs a command named by `runCommand`.

Sources are registered by name in the registry config and compiled code
share (`defineSource`, `Editor/Setup.lean`; `Editor/Config/Registry.lean`,
"Sources").

## Where an addition goes

| Addition | Where |
|---|---|
| Something more a source is asked | A field of `Query` (`Editor/Completion/Candidate.lean`), filled where `prompt` asks |
| Something more a candidate carries | A field of `Candidate`, optional, and what draws it is the display's |
| A shipped source | A value beside the rule it lists, given to the prompt that asks for it, registered compiled in `Headless.shippedOver`, and run by `ModelTest.sourceContractChecks` |
| A rule every source keeps | A property of `Editor/Completion/Contract.lean` |

Pinned by `ModelTest.sourceContractChecks` (the contract, on the model,
the fake and the shipped sources), `candidateChecks` (sources asked by a
prompt through the loop), `dispatchStateChecks` (a named source run
inside the asking command), `setupChecks` and `registryChecks`
(registration), and `ConfigTest.promptChecks` (a source from config, on
the real elaborator).
-/

namespace Editor.Completion

/-- What supplies candidates: a name, a category, and the candidates it
answers a query with. -/
structure Source where
  /-- The name it is registered and asked under, and its candidates'
  group. -/
  name : String
  /-- What it lists, as a word. -/
  category : String
  /-- The candidates it answers `query` with. -/
  candidates : (query : Query) → EditorM (Array Candidate)

/-- The model of a source: one called `name`, of `category`, that answers
`all` whatever it is asked, and asks the port nothing. -/
def Source.fixed (name category : String) (all : Array Candidate) : Source :=
  { name, category, candidates := fun _ => pure all }

/-- The model of a source over plain texts: `Source.fixed` with a candidate
of each of `texts`, in order. -/
def Source.ofTexts (name category : String) (texts : Array String) : Source :=
  Source.fixed name category (texts.map Candidate.ofText)

/-- A source as a prompt is asked with it: by the name it is registered
under, or as a value. -/
inductive SourceRef where
  /-- The source registered under `name`. -/
  | named (name : String)
  /-- `source` itself. -/
  | given (source : Source)

/-- `candidate` as a prompt holds it when the source `source` answered it:
in its own group, or, with none, in the source's. -/
def Candidate.inGroup (candidate : Candidate) (source : String) : Candidate :=
  { candidate with group := candidate.group <|> some source }

end Editor.Completion
