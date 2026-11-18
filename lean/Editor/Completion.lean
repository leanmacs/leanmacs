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
- **A category**, a word for what it lists (`buffer`, `ex-line`). A
  prompt's category is its first source's, and chooses the style its
  candidates are matched with (`Editor/Completion/Style.lean`).
- **Whether it has filtered already** (`filtered`): a source that matched
  the query itself. Its candidates are not matched again: they are listed
  after the style's matches, in the order it gave.
- **A function from a query to candidates** (`Query`, `Candidate`,
  `Editor/Completion/Candidate.lean`): a program over the editor's port,
  so it may ask what a command may, the state and a text, and has no `IO`
  and cannot wait. It reads and does not write: that is the contract.

It answers now, inside the command that asks, unless it **answers later**
(`later`, `Source.answeringLater`): then its function is never run, and the
registered job it names answers, in batches, as they come, asked once or
again as the text changes (`Reask`). How that goes is in
`Editor/Completion/Later.lean`.

## Asking one

A prompt is asked with a list of `SourceRef`s: a source given as a value,
or one named, which the loop that runs the asking command looks up among
the registered sources (`ControlRequest.askSource`,
`Editor/Command/Dispatch.lean`). A source is a program over the port a
request is part of, so a request cannot hold one, nor a reply: the name
crosses, and the loop runs the source it stands for inside the asking
command, as it runs a command named by `runCommand`.

A prompt may also ask for a category (`.category category defaults`): it
is answered by every source registered in the category, compiled and
config alike, in registration order (`RegistryRequest.categorySources`,
`Config.Registry.sourcesIn`). The defaults are what the prompt lists on a
host that registered nothing; each is asked by name where a source of its
name is registered in the category, so config's source of a shipped name
replaces it in place, and the category's other sources follow the
defaults. A category with no source and no defaults asks nothing, and the
prompt opens with no candidates. The defaults never cross a request: the
names cross, as for `.named`. The shipped prompts ask by category, with
their own sources as defaults, so config adds to what they list and
replaces it.

Sources are registered by name in the registry config and compiled code
share (`defineSource`, `Editor/Setup.lean`; `Editor/Config/Registry.lean`,
"Sources").

## Where an addition goes

| Addition | Where |
|---|---|
| Something more a source is asked | A field of `Query` (`Editor/Completion/Candidate.lean`), filled where `prompt` asks, as `Query.place` is |
| Something more a candidate carries | A field of `Candidate`, optional, and what draws it is the display's; one that crosses from a job is an argument of `Candidate.arguments` (`Editor/Completion/Later.lean`) |
| A rule for what a source hides until the text reveals it | The source's `Candidate.hiddenUntil`; the listing's projection is `Candidates.answering` (`Editor/State.lean`) |
| A shipped source | A value beside the rule it lists, a default of the category the prompt that lists it asks for, registered compiled in `Headless.shippedOver`, and run by `ModelTest.sourceContractChecks` |
| A way to match candidates | A style (`Editor/Completion/Style.lean`), not a source |
| A rule every source keeps | A property of `Editor/Completion/Contract.lean` |
| A source asked at a position of a buffer | An at-point source (`Editor/Completion/AtPoint.lean`), which names the sources to complete its region from (`Named`, `Named.ref`) |

Pinned by `ModelTest.sourceContractChecks` (the contract, on the model,
the fake and the shipped sources), `candidateChecks` (sources asked by a
prompt through the loop), `dispatchStateChecks` (a named source run
inside the asking command, and the names of a category's sources),
`apiStateChecks` (a category with no source), `setupChecks` and
`registryChecks` (registration, and a category's sources), and
`ConfigTest.promptChecks` (a source from config, on the real elaborator,
asked by name and added to a shipped prompt by its category). A source that
answers later is pinned by `ModelTest.laterChecks`, `completionJobChecks`
and `laterLoopChecks`, and by `ConfigTest.promptChecks` over the recorder;
one asked again by its directory part, with hidden candidates and a job's
failure, by `ModelTest.directoryChecks`; the file source by
`ModelTest.pathsChecks`, `fileNameChecks` and
`ConfigTest.filePromptChecks`.
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
  /-- Whether it has filtered for the query already: its candidates are
  then listed in the order it gave, after the matches, and not matched
  (`Candidates.list`, `Editor/State.lean`). -/
  filtered : Bool := false
  /-- How it answers later, when it does: then `candidates` is never run,
  and the registered job it names answers, in batches
  (`Editor/Completion/Later.lean`). -/
  later : Option Later := none

/-- A source called `name`, of `category`, that answers later, from the job
registered under `job`, asked again as `reask` says: its `candidates` are
never run. -/
def Source.answeringLater (name category job : String) (reask : Reask := .never)
    (filtered : Bool := false) : Source :=
  { name, category, candidates := fun _ => pure #[], filtered, later := some { job, reask } }

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
  /-- Every source registered in `category`, `defaults` first: each default
  is asked by name where a source of its name is registered in the
  category, and as itself otherwise, and the other registered sources come
  after them, in registration order. -/
  | category (category : String) (defaults : List Source)

/-- The reference to every source registered in `category`, with no
defaults. -/
def SourceRef.ofCategory (category : String) : SourceRef :=
  .category category []

/-- The reference a source an at-point source names stands for
(`Completion.Named`, `Editor/Completion/AtPoint.lean`): the source of the
name, or every source of the category, with no defaults. -/
def Named.ref : Named → SourceRef
  | .source name => .named name
  | .category named => .ofCategory named

end Editor.Completion
