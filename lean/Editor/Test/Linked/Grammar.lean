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
tree on the real syntax tree binding, waits for the library to deliver its
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
with it as the `code` mode enters it. Refused when a sentence would be said
or the language is left with no tree. -/
def enteredDeclared (declared : List Language.Grammar) (language : Language) (text : TextId)
    (replies : Array Language.Grammar.Reply) : EditorM Unit := do
  let (answers, sentences) ← Language.Grammar.answersOf {} 1 replies
  unless sentences.isEmpty do
    throw .noSuchText
  let some tree := Language.Grammar.treeOf declared answers 1 language.syntaxTree
    | throw .noSuchText
  Highlight.enter Language.codeName text tree

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
answers (`enteredDeclared`) on the real syntax tree binding, its tree
delivered, is published in a view 160 by 64 scrolled to the byte `scroll`,
the faces drawn as `theme` says. None when the job did not finish with its
command, the text could not be made or entered, a sentence would be said,
or the scene was not published. The library's reports of the parses are
drained from the editor queue before the publish. -/
def declaredDrawn (services : Services) (platform : String) (grammars : Array Language.Grammar)
    (language : Language) (source : String) (theme : Theme) (scroll : Nat) : IO (Option String) :=
  do
  let display ← Ffi.Display.newCells 8 16
  let shown ← RealDisplay.over display services.published.reader theme
  let made : EditorM TextId := createText source
  let (.ok text, texts) ← made.runReal (.over services.published) shown.handle | return none
  let handle ←
    Job.spawn services.jobs
        (Work.of (fun _ => Language.Grammar.register platform grammars)
          (enteredDeclared grammars.toList language text))
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

end Editor.Test.Linked
