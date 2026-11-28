import Editor.Api
import Editor.Job
import Editor.Language.Grammar

/-!
# Registering config's grammars: the core's `register-grammars` job

What a `registerGrammars` effect (`Editor/Config/Reload.lean`) starts, an
install's, or that of the packages' grammars alone at a start with no
config or after a first reload that is rejected ("The packages' grammars
with no config", there): the core's own job (`Language.Grammar.work`), owned by `config`,
that registers each grammar of the registry's table and reads its query
files, and the command it finishes with (`installed`), which records the
answers, has the open buffers of those grammars' languages highlighted
again, and says each refusal.

## Why it is a job

A registration is a request of the job port (`Grammar.register`,
`Editor/SyntaxTree/Registration.lean`, "Why it is a job's request"), and
so is a query file's read (`File.load`): each waits, and the editor thread
never waits. Neither can be made from `EditorM`, where a wait is a type
error (`Editor/Job.lean`, "The split, checked when this module is
compiled"). So the editor thread does three things of its own: it starts
the job when the reducer asks, it runs the job's command, and between the
two it goes on with keys and other events.

## The job (`register`)

For each declaration, in the table's order: `Grammar.register` of its
source on the platform the job is given (`Language.Grammar.sourceOn`), and,
when that registered, `File.load` of each query file in its query directory
(`Language.Grammar.queryFiles`) under `Language.Grammar.queryLimit`. A
refusal of either is a value in the reply (`Reply`), never a failure of the
job. A declaration with no library for the platform (a per-platform one
that does not list it) is refused in the reply, `failed` with
`Language.Grammar.noLibraryFor`, before the service is asked: the error
already means a registration that failed on the way to the service, so the
port's error gains no constructor.

## Its command (`installed`), on the editor thread, in order

1. **The answers** (`answersOf`): each loaded query's text is read (taken
   into the text store, read and released), a missing file is no query of
   its kind, and any other refusal of a load is no query too and a
   sentence (`Language.Grammar.unread`). `SyntaxTree.grammars` is asked
   once, so a refused name is known to be still listed (registered before:
   the library compiles in no grammar) or not; the refusal's sentence says which
   (`Language.Grammar.said`). Every name registered is recorded among the
   names this process has registered, with the queries just read in place
   of any read at an earlier registration (`Answers.registered`), so a
   later refusal of the name keeps them.
2. **Recorded** in the editor state, stamped with the generation the
   install set (`setGrammarAnswers`).
3. **Highlighted again**: every open buffer whose language names a declared
   grammar (`rehighlightGrammars`, `Editor/Command/Dispatch.lean`), so a
   buffer opened while the job ran, drawn plain then, gets its tree now;
   every other highlighted buffer is injected into again, so its fences of
   a declared grammar take the answered queries.
4. **Said** last, joined by `; ` into one echo text, so no message from a
   highlight hides them.

## How the order is kept

The job is owned by `config`, so the next install's `cancelJobs config`
removes it before that install starts its own, and its command never runs.
Should an older generation's command run all the same, it does nothing
once answers of a later generation are recorded, so it cannot replace
them. Answers of an older generation are never read
(`Language.Grammar.Answers.answerOf?`), and a buffer whose mode is set
before the command is drawn plain (`Language.Grammar.treeOf`), so no
buffer's tree depends on when the job ends.

Pinned by `ModelTest.grammarRegisterChecks` (from the reducer's effect,
through `Loop.Driver`, on the job model and the editor's models), by
`ConfigTest.reloadEchoChecks` (the host's start of the job, and the next
install's cancel of it, on the stepped host), and by `ContractTest.grammarDeclarationChecks` (the job on the real
grammar and file services, and the command on the real syntax tree).
-/

namespace Editor

/-- What the job brought back for one declaration: the registration's
refusal, or each query file's name and its load. -/
structure Language.Grammar.Reply where
  /-- The declaration. -/
  grammar : Language.Grammar
  /-- Why the registration did not register, or each query file's name and
  what its load answered, in `queryFiles`' order. -/
  outcome : Except GrammarError (Array (String × Except FileError File.Loaded))

namespace Language.Grammar

/-- The job: each of `grammars` registered, in order, from its library on
`platform`, and the query files of each one that registered loaded from its
query directory. A declaration with no library for `platform` is refused in
the reply (`noLibraryFor`), and the service is not asked. -/
def register (platform : String) (grammars : Array Language.Grammar) : JobM (Array Reply) :=
  grammars.mapM fun grammar => do
    let some source := grammar.sourceOn platform
      | return { grammar, outcome := .error (.failed (noLibraryFor platform)) }
    match ← Editor.Grammar.register source with
    | .error error =>
      return { grammar, outcome := .error error }
    | .ok _ =>
      let loads ←
        queryFiles.toArray.mapM fun (file, _) => do
            return (file, ← File.load (grammar.queries / file) queryLimit)
      return { grammar, outcome := .ok loads }

/-- The queries `loads` read, and a sentence for each load refused for
another reason than a missing file. Each loaded text is taken into the
text store, read and released. -/
def queriesOf (grammar : Language.Grammar) (loads : Array (String × Except FileError File.Loaded)) :
    EditorM (Queries × Array String) := do
  let mut queries : Queries := {}
  let mut sentences := #[]
  for (file, load) in loads do
    let some (_, kind) := queryFiles.find? (·.1 == file) | continue
    match load with
    | .ok loaded =>
      let text ← loaded.snapshot.toText
      let source ← (text.read : TextM String)
      (text.release : TextM Unit)
      queries := queries.set kind (some source)
    | .error .notFound =>
      pure ()
    | .error error =>
      sentences := sentences.push (unread grammar file error)
  return (queries, sentences)

/-- The answers of `replies` for the config generation `generation`, over
the answers recorded before, `previous`, and the sentences to say, in
order: step 1 of the module docs. `SyntaxTree.grammars` is asked once. -/
def answersOf (previous : Answers) (generation : Nat) (replies : Array Reply) :
    EditorM (Answers × Array String) := do
  let known := ((← SyntaxTree.lift SyntaxTree.grammars).toOption).getD #[]
  let mut answers := #[]
  let mut registered := previous.registered
  let mut sentences := #[]
  for reply in replies do
    let name := reply.grammar.name
    match reply.outcome with
    | .error error =>
      let kept := known.contains name
      answers := answers.push (name, .refused error kept)
      sentences := sentences.push (said name error kept)
    | .ok loads =>
      let (queries, unreadSentences) ← queriesOf reply.grammar loads
      answers := answers.push (name, .registered queries)
      registered := (registered.filter (·.1 != name)).push (name, queries)
      sentences := sentences ++ unreadSentences
  return ({ generation, answers, registered }, sentences)

/-- The job's command: the answers recorded for `generation`, every buffer
of a declared grammar's language highlighted again, and the sentences said
last (the module docs); nothing at all when the answers recorded are of a
later generation. -/
def installed (generation : Nat) (replies : Array Reply) : EditorM Unit := do
  let previous := (← editorState).grammars
  if previous.generation > generation then
    return
  let (answers, sentences) ← answersOf previous generation replies
  setGrammarAnswers answers
  rehighlightGrammars (replies.map (·.grammar.name))
  unless sentences.isEmpty do
    message ("; ".intercalate sentences.toList)

/-- The work of the core's `register-grammars` job for `grammars`, the
registry's table, installed with the config generation `generation`, each
registered from its library on `platform`. -/
def work (platform : String) (generation : Nat) (grammars : Array Language.Grammar) : Work :=
  Work.of (fun _ => register platform grammars) (installed generation)

end Language.Grammar

end Editor
