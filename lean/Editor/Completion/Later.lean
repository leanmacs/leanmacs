import Editor.Api
import Editor.Job

/-!
# Sources that answer later

A completion source (`Editor/Completion.lean`) that cannot answer before the
next key, a file list over a large project, a project search or a language
server, answers from a job (`Editor/Job.lean`), in batches, as they come.

## How it answers

- **The source says so** (`Source.later`, a `Completion.Later`): the name of
  the registered job that answers, and when it is asked again
  (`Completion.Reask`). Its `candidates` are never run: `prompt` records it
  and starts nothing (`Editor/Api.lean`, "Prompts"), and the prompt holds it
  as an asking source (`Completion.Asking`, `Editor/State.lean`, "Prompts").
- **The loop starts its job**, after the publish that follows the asking
  step (`Loop.completionJobs`, `Editor/Loop.lean`, "Prompts"), under the key
  `completion <view> <source>`, with an order (`Order`): the prompt's view,
  the source's index among the asking ones, the generation of the ask, the
  query and a pause.
- **The job posts its batches** (`answering`): each is a `post` of the
  command `minibuffer-candidates` (`candidatesCommand`) with the batch as
  plain arguments (`batchArguments`), so batches arrive in order, between
  events, before the job's end, and a cancelled job's are dropped, all as
  any post is. The command takes the batch into the prompt
  (`StateRequest.addCandidates`), and the scene after it lists it. The
  job's own command marks the source done (`StateRequest.sourceAnswered`).
- **A generation is the ask a batch belongs to.** A source that depends on
  the text (`Reask.afterPause`) is asked again when the text it was asked
  with is not the typed text: the previous job is cancelled, and a job of the
  next generation starts with the typed text, after the pause. A batch of
  an older generation is dropped. What the source answered stays listed
  until the new generation's first batch, or its end.
- **Closing the prompt cancels its jobs**, by their keys, at the publish of
  the closing step.

## The model of such a job

`Later.batches` answers the batches it is given in turn, whatever the
query, and `Later.echoing` one batch of one candidate, the query's text with
`!` after it, for tests that see which text was asked. They are made with
`answering`, the only way a source's job is built, so what they do is what
any source's job does; it is pinned on the job model by
`ModelTest.laterChecks`.

## Where an addition goes

| Addition | Where |
|---|---|
| A new way to ask again | A constructor of `Completion.Reask` and its case of `Reask.asksAgain` (`Editor/Completion/Candidate.lean`) |
| Something more a source's job is handed | A field of `Order`, or of its `Query`, and its argument in `Order.arguments` and `Order.ofArguments?` |
| A source's job | A function given to `answering`, registered with `sourceJob` (`Editor/Setup.lean`) |

Pinned by `ModelTest.laterChecks`, `completionJobChecks` and
`candidateChecks`, and over the recorder by `ConfigTest.promptChecks`.
-/

namespace Editor.Completion

/-- What a source's job is started with: where its batches go and what it is
asked. -/
structure Order where
  /-- The view of the prompt that asks. -/
  view : ViewId
  /-- The source's index among the prompt's asking sources. -/
  index : Nat
  /-- The generation of the ask. -/
  generation : Nat
  /-- What the source is asked. -/
  query : Query
  /-- How long the job waits before it asks, in milliseconds. -/
  pause : Nat := 0
  deriving DecidableEq, Repr

/-- `order` as the plain arguments a job is started with: the view, the
index, the generation, the query's text and view and the pause, then the
query's region, its two ends or `false` for none, then each snapshot id of
its texts. -/
def Order.arguments (order : Order) : List Argument :=
  let region :=
    match order.query.region with
    | some span => [.nat span.start, .nat span.stop]
    | none => [.bool false]
  [.nat order.view.index, .nat order.index, .nat order.generation, .str order.query.text,
      .nat order.query.view.index, .nat order.pause] ++
    region ++
    order.query.texts.toList.map fun snapshot => .nat snapshot.index

/-- The snapshot ids `arguments` hold, each a number; `none` for arguments
that are not all numbers. -/
def snapshotsOfArguments? (arguments : List Argument) : Option (Array SnapshotId) :=
  arguments.toArray.mapM fun
    | .nat index => some ⟨index⟩
    | _ => none

/-- The order `arguments` hold; `none` for arguments that are not one. The
six arguments of an order with no region and no texts are taken too. -/
def Order.ofArguments? : List Argument → Option Order
  | [.nat view, .nat index, .nat generation, .str text, .nat asker, .nat pause] =>
    some { view := ⟨view⟩, index, generation, query := { text, view := ⟨asker⟩ }, pause }
  | .nat view :: .nat index :: .nat generation :: .str text :: .nat asker :: .nat pause :: rest =>
    let parsed : Option (Option Span × List Argument) :=
      match rest with
      | .bool false :: rest => some (none, rest)
      | .nat start :: .nat stop :: rest => some (some { start, stop }, rest)
      | _ => none
    parsed.bind fun (region, rest) =>
      (snapshotsOfArguments? rest).map fun texts =>
        { view := ⟨view⟩, index, generation, query := { text, view := ⟨asker⟩, region, texts }
          pause }
  | _ => none

/-- An optional field of a candidate as an argument: its text, or `false`
for none. -/
def optionalArgument : Option String → Argument
  | some text => .str text
  | none => .bool false

/-- The optional field an argument holds: its text, or none for `false`;
`none` for an argument that is neither. -/
def optionalOfArgument? : Argument → Option (Option String)
  | .str text => some (some text)
  | .bool false => some none
  | _ => none

/-- `candidate` as five arguments: its text, then its label, annotation,
kind and group, each a string or `false` for none. -/
def Candidate.arguments (candidate : Candidate) : List Argument :=
  [.str candidate.text, optionalArgument candidate.label, optionalArgument candidate.annotation,
    optionalArgument candidate.kind, optionalArgument candidate.group]

/-- The candidates `arguments` hold, five arguments each, after
`gathered`; `none` for arguments that are not candidates. -/
def candidatesOfArguments? (gathered : Array Candidate) : List Argument → Option (Array Candidate)
  | [] => some gathered
  | .str text :: label :: annotation :: kind :: group :: rest => do
    let candidate : Candidate :=
      { text, label := ← optionalOfArgument? label, annotation := ← optionalOfArgument? annotation
        kind := ← optionalOfArgument? kind, group := ← optionalOfArgument? group }
    candidatesOfArguments? (gathered.push candidate) rest
  | _ => none

/-- A batch of the source `index` of the prompt in `view`, at `generation`,
as the arguments of `minibuffer-candidates`. -/
def batchArguments (view : ViewId) (index generation : Nat) (batch : Array Candidate) :
    List Argument :=
  [.nat view.index, .nat index, .nat generation] ++ batch.toList.flatMap Candidate.arguments

/-- The view, the source's index, the generation and the batch `arguments`
hold; `none` for arguments that are not a batch. -/
def batchOfArguments? : List Argument → Option (ViewId × Nat × Nat × Array Candidate)
  | .nat view :: .nat index :: .nat generation :: rest =>
    (candidatesOfArguments? #[] rest).map fun batch => (⟨view⟩, index, generation, batch)
  | _ => none

/-- The command a source's job posts its batches as: the minibuffer's
(`Editor/Minibuffer.lean`), which takes a batch into the open prompt. -/
def candidatesCommand : String :=
  "minibuffer-candidates"

/-- A source's job, from `answer`: what it does with a query, given how to
deliver a batch. Started with an order's arguments, it decodes the order
(and fails on arguments that are not one), waits the order's pause when
there is one, runs `answer` with a delivery that posts each batch to
`minibuffer-candidates`, and finishes with the command that marks the
source done. -/
def answering (answer : Query → (Array Candidate → JobM Unit) → JobM Unit)
    (arguments : List Argument) : Work := fun _ => do
  let some order :=
    Order.ofArguments? arguments | throw "a completion source's job was started with no order"
  if order.pause != 0 then
    sleep order.pause
  answer order.query fun batch =>
      post
        { command := candidatesCommand
          arguments := batchArguments order.view order.index order.generation batch }
  return EditorState.ask (.sourceAnswered order.view order.index order.generation)

/-- The model of a source's job: answers each of `batches` in turn, whatever
it is asked. -/
def Later.batches (batches : Array (Array Candidate)) : List Argument → Work :=
  answering fun _ deliver => batches.forM deliver

/-- The model of a source's job that depends on the text: answers one batch,
a candidate of the text it was asked with `!` after it. -/
def Later.echoing : List Argument → Work :=
  answering fun query deliver => deliver #[.ofText (query.text ++ "!")]

end Editor.Completion
