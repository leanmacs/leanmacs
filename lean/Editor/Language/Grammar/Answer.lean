import Editor.SyntaxTree.Registration

/-!
# What the registration of config's grammars answered

The answers the core's `register-grammars` job brings back for the grammars
config declares (`Editor/Language/Grammar.lean`), as the editor state keeps
them (`EditorState.grammars`, set by `StateRequest.setGrammars`): for each
declared name, registered with the queries read from its query directory,
or refused, and whether the syntax service still lists the name after the
refusal. It is a module of its own, importing only the registration's data,
so the state requests can name it without importing the language table, as
`Editor/Language/IndentUnit.lean` is.

- **`generation`** is the config generation the answers were recorded for
  (`Registry.generation`). An answer is found only under it
  (`Answers.answerOf?`): the answers of an older config are never read, so
  a reload that declares nothing needs no job, and a stale query never
  applies.
- **`answers`** holds each declared name's answer, in declaration order.
- **`registered`** is every name this process has registered, across
  generations: phase 1 has no unregister, so a name stays registered in the
  library once it was. It says which consequence a refusal's sentence names
  (`Language.Grammar.said`).

Pinned by `ModelTest.grammarAnswerChecks`.
-/

namespace Editor

/-- The queries read from a declared grammar's query directory, one source
for each kind; `none` for a kind with no file. -/
structure Language.Grammar.Queries where
  /-- `highlights.scm`. -/
  highlights : Option String := none
  /-- `injections.scm`. -/
  injections : Option String := none
  /-- `textobjects.scm`. -/
  textObjects : Option String := none
  /-- `indents.scm`. -/
  indents : Option String := none
  deriving DecidableEq, Repr

/-- What the registration of one declared grammar answered. -/
inductive Language.Grammar.Answer where
  /-- It registered, and these are the queries read from its directory. -/
  | registered (queries : Language.Grammar.Queries)
  /-- It was refused with `error`; `kept` says whether the syntax service
  still lists its name (compiled in, or registered before). -/
  | refused (error : GrammarError) (kept : Bool)
  deriving DecidableEq, Repr

/-- The answers recorded for config's declared grammars, stamped with the
config generation they were recorded for. -/
structure Language.Grammar.Answers where
  /-- The config generation the answers are of. -/
  generation : Nat := 0
  /-- Each declared name's answer, in declaration order. -/
  answers : Array (String × Language.Grammar.Answer) := #[]
  /-- Every name this process has registered, across generations. -/
  registered : Array String := #[]
  deriving DecidableEq, Repr

/-- The answer recorded for `name` under `generation`; `none` when none is,
or the answers are of another generation. -/
def Language.Grammar.Answers.answerOf? (answers : Language.Grammar.Answers) (generation : Nat)
    (name : String) : Option Language.Grammar.Answer :=
  if answers.generation == generation then (answers.answers.find? (·.1 == name)).map (·.2) else none

end Editor
