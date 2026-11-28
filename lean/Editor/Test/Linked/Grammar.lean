import Editor.Command
import Editor.Display
import Editor.Display.Real
import Editor.Ffi.Display
import Editor.Ffi.Syntax
import Editor.Highlight
import Editor.InferredWait
import Editor.Job
import Editor.Job.Real
import Editor.Job.Runner
import Editor.Language
import Editor.Language.Grammar
import Editor.Language.Grammar.Answer
import Editor.Language.Grammar.Register
import Editor.ModuleLookup
import Editor.RealHost
import Editor.Scene
import Editor.SyntaxTree
import Editor.SyntaxTree.Real
import Editor.Test.Linked.Jobs
import Editor.Test.Linked.Services
import Editor.Test.Linked.Syntax
import Editor.Text
import Editor.Text.Real

/-!
# The linked test kit: Grammar

A declared grammar from its declaration to a drawn frame, over the
library's real services, as the core's `register-grammars` job and its
command take it (`Editor/Language/Grammar/Register.lean`), with no host:
`declaredDrawn` registers declarations through the library's grammar
registrations on a platform, reads the answers and resolves a language's
tree as the core's command does, enters a text of the language with that
tree on the real syntax tree binding, each injected language with the tree
the core's dispatch gives it over the languages handed in, so a declared
grammar injected into it (Markdown's inline grammar, into Markdown) takes
its declared queries, waits for the library to deliver its
tree, and publishes a view of it to the real display over cells, whose
frame text it returns, each run of the cells with its colours. A check
compares the runs it expects.

The core's contract check of a declared grammar
(`ContractTest.declaredGrammarDrawnCheck`) is written on it, and so is a
package's check of the grammar it ships, which may not import the raw
bindings or contract-test's support (`docs/design/packages.md`, "What a
package may import").

`stagedGrammarsDirectory` reads where a set's build staged a Lake package's
grammars directory, from the record beside the set's editor, with the real
file read (`ModuleLookup.grammarDirectories`), so a package's linked test
reads the record without importing `Editor.ModuleLookup`, which is
internal. What it reads is pinned by `ModelTest.moduleLookupChecks`.

`declaredRegistered` says, for each of a set of declarations, whether it
registers and its queries compile, with no text entered and nothing drawn:
it runs the core's job (`Language.Grammar.register`) through the library's
grammar and file services, as `declaredDrawn` does, and finishes with a
command on the real syntax tree that reads the replies as the core's
command does (`Language.Grammar.answersOf`) and compiles, then releases,
each query a registered grammar read (`Highlight.withQuery`). A grammar's
problem is its refusal's sentence (`Language.Grammar.said`), the sentences
the core says of its query files' loads (`Language.Grammar.queriesOf`, so
which refusal of a load is a problem stays the core's rule), no highlights
query, or a
query the library refuses to compile, naming its kind. The command writes
its report into a text the helper made before spawning the job, which the
helper reads back, since a job's command returns nothing. A package's
check of every grammar it ships is written on it. What it reads is pinned
by `ModelTest.grammarRegisterChecks` and the contract checks.

Published for a package's linked tests, in the namespace
`Editor.Test.Linked`, as the rest of the linked kit is. It holds no checks
of its own.
-/

namespace Editor.Test.Linked

open Editor

/-- The directory the set's build staged the grammars directory of the Lake
package `lake` in, as the record beside the set's editor `editor` names it
(`ModuleLookup.grammarDirectories`, over the real file read); none when the
record is missing or cannot be read, or names none for `lake`. -/
def stagedGrammarsDirectory (editor : System.FilePath) (lake : String) :
    IO (Option System.FilePath) := do
  let read (path : System.FilePath) : IO (Option String) := do
    try
      return some (← IO.FS.readFile path)
    catch _ =>
      return none
  let directories ← ModuleLookup.grammarDirectories editor.toString read
  return (directories.find? (·.1 == lake)).map (·.2)

/-- The command the registration's job finishes with, given what the job
brought back: the answers read as the core's command reads them
(`Language.Grammar.answersOf`), `language`'s tree resolved against them and
the declarations `declared` (`Language.Grammar.treeOf`), and `text` entered
with it as the `code` mode enters it, each injected language with the tree
the core's dispatch gives it (`Language.Grammar.injectedTreeOf`) over
`languages`, the registered languages in precedence order, so a declared
grammar's injected languages take their declared queries. Refused when a
sentence would be said or the language is left with no tree. -/
def enteredDeclared (declared : List Language.Grammar) (language : Language)
    (languages : List Language) (text : TextId) (replies : Array Language.Grammar.Reply) :
    EditorM Unit := do
  let (answers, sentences) ← Language.Grammar.answersOf {} 1 replies
  unless sentences.isEmpty do
    throw .noSuchText
  let some tree := Language.Grammar.treeOf declared answers 1 language.syntaxTree
    | throw .noSuchText
  Highlight.enter Language.codeName text tree (injected :=
      Language.Grammar.injectedTreeOf declared answers 1 languages)

/-- `declaredDrawn` is an inferred wait (`Editor/InferredWait.lean`): it
hands on `Ffi.syntaxSettle`, the real syntax service's readout, so a check
that draws a declared grammar over the real binding says why with an
allow. -/
def declaredDrawn.inferredWait : InferredWait :=
  .realEffect []

/-- The mark of `declaredDrawn`: it runs real background services
(`Editor/RealHost.lean`). -/
def declaredDrawn.realHost : RealHost :=
  .service

/-- The frame text of the real display over cells, 8 by 16 a cell, once the
declarations `grammars` are registered on `platform` through `services`'
grammar registrations by the core's job (`Language.Grammar.register`), and
a text of `source`, entered with `language`'s tree resolved against the
answers (`enteredDeclared`), its injected languages' trees taken from
`languages` (by default, `language` alone), on the real syntax tree binding,
its tree delivered, is published in a view 160 by 64 scrolled to the byte
`scroll`, the faces drawn as `theme` says. None when the job did not finish
with its command, the text could not be made or entered, a sentence would
be said, or the scene was not published. The library's reports of the
parses are drained from the editor queue before the publish. -/
def declaredDrawn (services : Services) (platform : String) (grammars : Array Language.Grammar)
    (language : Language) (source : String) (theme : Theme) (scroll : Nat)
    (languages : List Language := [language]) : IO (Option String) := do
  let display ← Ffi.Display.newCells 8 16
  let shown ← RealDisplay.over display services.published.reader theme
  let made : EditorM TextId := createText source
  let (.ok text, texts) ← made.runReal (.over services.published) shown.handle | return none
  let handle ←
    Job.spawn services.jobs
        (Work.of (fun _ => Language.Grammar.register platform grammars)
          (enteredDeclared grammars.toList language languages text))
        (pure ())
  discard <| hangGuarded "the registration job's end" handle.outcome.result?
  let some (.finished command) ← handle.outcome? | return none
  let real ← RealSyntaxTree.new services.published.reader
  let syntaxTree := settlingAttach services.published real.handle
  let (entered, texts) ←
    Job.finishWith services.held handle command texts shown.handle (syntaxTree := syntaxTree)
  unless entered.isOk do
    return none
  let viewed : EditorM (SnapshotId × MarkerId) := do
    return (← text.snapshot, ← text.mark (.anchor { offset := scroll, bias := .before }))
  let (.ok (snapshot, scrolled), texts) ← viewed.runReal texts shown.handle | return none
  let some found ← services.published.find? snapshot | return none
  unless ← Ffi.syntaxSettle found Ffi.treeGuard do
    return none
  discard drainedParsed
  let scene : Scene :=
    { size := { width := 160, height := 64 }
      views :=
        #[{ id := ⟨0⟩, rect := { x := 0, y := 0, width := 160, height := 64 }, snapshot
            scroll := scrolled, selections := #[], cursor := { shape := .block, face := ⟨"cursor"⟩ }
            decorations := #[], status := #[] }]
      focused := none, echo := "", pending := "", preedit := none }
  let publish : EditorM Unit := Display.publish scene
  let (published, _) ← publish.runReal texts shown.handle
  unless published.isOk do
    return none
  return some (← display.frameText)

/-- What is wrong with the grammar of `reply`, which registered and read
`queries`: the sentences the core says of its query files' loads
(`Language.Grammar.queriesOf`, which decides which refusal of a load is
one), joined by `; `; no highlights query; or a query the real syntax tree
refuses to compile, naming its kind; none when nothing is. Each query
compiled is released. -/
def registeredProblem (reply : Language.Grammar.Reply) (queries : Language.Grammar.Queries) :
    EditorM (Option String) := do
  if let .ok loads := reply.outcome then
    let (_, sentences) ← Language.Grammar.queriesOf reply.grammar loads
    unless sentences.isEmpty do
      return some ("; ".intercalate sentences.toList)
  if queries.highlights.isNone then
    return some "no highlights query"
  let sources : List (QueryKind × Option String) :=
    [(.highlights, queries.highlights), (.injections, queries.injections),
      (.textObjects, queries.textObjects), (.indents, queries.indents),
      (.rendered, queries.rendered), (.renderedInjections, queries.renderedInjections)]
  for (kind, source) in sources do
    let some source := source | continue
    match ← SyntaxTree.lift (Highlight.withQuery reply.grammar.name source fun _ => pure ()) with
    | .ok () =>
      pure ()
    | .error error =>
      return some s!"its {kind.name} query: {error.describe}"
  return none

/-- Each declaration of `replies`, in order, with its problem: its
refusal's sentence (`Language.Grammar.said`) when it was refused, else
`registeredProblem`'s; none when there is none. The replies are read as
the core's command reads them (`Language.Grammar.answersOf`). -/
def registeredProblems (replies : Array Language.Grammar.Reply) :
    EditorM (Array (String × Option String)) := do
  let (answers, _) ← Language.Grammar.answersOf {} 1 replies
  let mut report := #[]
  for (reply, name, answer) in replies.zip answers.answers do
    let problem ←
      match answer with
      | .refused error kept =>
        pure (some (Language.Grammar.said name error kept))
      | .registered queries =>
        registeredProblem reply queries
    report := report.push (name, problem)
  return report

/-- `report` as the text `declaredRegistered`'s command writes: a line for
each declaration, its name, then a tab and its problem, with any line break
in it made a space, when it has one. -/
def registeredReportText (report : Array (String × Option String)) : String :=
  String.join <|
    report.toList.map fun (name, problem) =>
      match problem with
      | some problem => s!"{name}\t{problem.replace "\n" " "}\n"
      | none => s!"{name}\n"

/-- The report `registeredReportText` wrote, read back. -/
def registeredReportOf (text : String) : Array (String × Option String) :=
  ((text.splitOn "\n").filter (!·.isEmpty)).toArray.map fun line =>
    match line.splitOn "\t" with
    | name :: problem :: rest => (name, some ("\t".intercalate (problem :: rest)))
    | _ => (line, none)

/-- The mark of `declaredRegistered`: it runs real background services
(`Editor/RealHost.lean`). -/
def declaredRegistered.realHost : RealHost :=
  .service

/-- Each of the declarations `grammars`, in order, with its problem
(`registeredProblems`), once they are registered on `platform` through
`services`' grammar registrations by the core's job
(`Language.Grammar.register`) and the job's command has read the replies
and compiled each query read on the real syntax tree binding. None when
the job did not finish with its command, or the report could not be
written or read. -/
def declaredRegistered (services : Services) (platform : String)
    (grammars : Array Language.Grammar) : IO (Option (Array (String × Option String))) := do
  let display ← Ffi.Display.newCells 8 16
  let shown ← RealDisplay.over display services.published.reader #[]
  let made : EditorM TextId := createText ""
  let (.ok report, texts) ← made.runReal (.over services.published) shown.handle | return none
  let written (replies : Array Language.Grammar.Reply) : EditorM Unit := do
    let text := registeredReportText (← registeredProblems replies)
    (report.insert 0 text : TextM Unit)
  let handle ←
    Job.spawn services.jobs (Work.of (fun _ => Language.Grammar.register platform grammars) written)
        (pure ())
  discard <| hangGuarded "the registration job's end" handle.outcome.result?
  let some (.finished command) ← handle.outcome? | return none
  let real ← RealSyntaxTree.new services.published.reader
  let (finished, texts) ←
    Job.finishWith services.held handle command texts shown.handle (syntaxTree := real.handle)
  unless finished.isOk do
    return none
  let read : EditorM String := (report.read : TextM String)
  let (.ok text, _) ← read.runReal texts shown.handle | return none
  return some (registeredReportOf text)

end Editor.Test.Linked
