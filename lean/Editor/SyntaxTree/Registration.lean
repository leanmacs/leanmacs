/-!
# Registering a grammar, as a job asks for it

The data of a grammar registration: where a grammar comes from
(`GrammarSource`, a native library, the symbol that hands out its language,
and the reparse policy its declaration gives, if any), why a registration is
refused (`RegistrationRefusal`), and the request a job makes
(`GrammarRequest`). It sits beside the syntax tree interface
(`Editor/SyntaxTree.lean`), whose grammars a registration adds to.

## Why it is a job's request

A registration is a request of the job port (`Editor/Job.lean`,
`JobRequest.grammar`, made with `Grammar.register`), not of the syntax tree
interface, because the editor thread never waits for it
(`docs/design/concurrency.md`, the threads table): the library answers it on
the syntax worker's thread, before that worker's next round and so behind
any round in progress, and loading a grammar is file I/O. A request of the
job port cannot be offered at `EditorM`, where a wait is a type error
(`Editor/Job.lean`, "The split, checked when this module is compiled"), so
no command can block on one. The answer comes back through the completion
queue, as a diff's does (`crates/editor-ffi/src/grammars.rs`).

## The rules

- **The name** a grammar is registered under is its source's symbol
  without the `tree_sitter_` prefix (`GrammarSource.name`): a symbol without
  that prefix, or with nothing after it, is its own name. It is the rule of
  the library's core (`GrammarSource::name`,
  `crates/editor-syntax/src/port.rs`), mirrored here.
- **The policy** is the one the source declares, and `whole` when it
  declares none: a grammar loaded at run time has not been swept for the
  incremental reparse's quality.
- **A later registration of a name replaces the earlier one**, and a
  registered grammar replaces a compiled-in one of the same name, for
  documents attached afterwards.
- **A refusal is a value** (`GrammarError.refused`), and leaves every
  grammar as it was. Each refusal of the library's crosses as one of its
  own: `RegistrationRefusal`'s constructors are the Rust enum's, one for
  one.
- **A registered grammar ships no query**: its queries are read from beside
  its library and handed in as a mode's override.

The pure model of the registry is `Editor/SyntaxTree/Registration/Model.lean`.

## Where an addition goes

A new registration request is a constructor of `GrammarRequest` with its
case in `GrammarRequest.Reply`, and an operation in `Editor/Job.lean`. It
needs a clause in the job model (`JobModel.handle`, over
`GrammarRegistry`), in the fake and the real grammar service of the job
runner (`Editor/Job/Fake.lean`, `Editor/Job/Real.lean`), and a property in
`JobContract.grammarProperties`. A new refusal is a constructor of
`RegistrationRefusal`, with its status in the binding
(`Ffi.grammarsTake`) and in `crates/editor-ffi/src/grammars.rs`.
-/

namespace Editor

/-- How a grammar's texts are reparsed after an edit: incrementally, reusing
the old tree, or whole, from scratch. -/
inductive ReparsePolicy where
  /-- Each reparse reuses the old tree, told the edits since. -/
  | incremental
  /-- Each reparse parses the text from scratch. -/
  | whole
  deriving DecidableEq, Repr, Inhabited

/-- Where a grammar registered at run time comes from: a native library, the
symbol it exports its language under, and the reparse policy its declaration
gives, if any. -/
structure GrammarSource where
  /-- The library's path. -/
  library : String
  /-- The symbol the library exports its language under:
  `tree_sitter_python`. -/
  symbol : String
  /-- The reparse policy the declaration gives; `none` is registered
  `whole`. -/
  policy : Option ReparsePolicy := none
  deriving DecidableEq, Repr, Inhabited

/-- The prefix a grammar's symbol carries before its name. -/
def GrammarSource.prefix : String :=
  "tree_sitter_"

/-- The name `source` is registered under: its symbol without the
`tree_sitter_` prefix (`tree_sitter_python` is `python`); a symbol without
that prefix, or with nothing after it, is its own name. -/
def GrammarSource.name (source : GrammarSource) : String :=
  if
      source.symbol.startsWith GrammarSource.prefix &&
        source.symbol.length > GrammarSource.prefix.length then
    source.symbol.drop GrammarSource.prefix.length |>.toString
  else source.symbol

/-- Why a registration was refused: the library's refusals, one for one. -/
inductive RegistrationRefusal where
  /-- No file is at the library's path. -/
  | notFound
  /-- The file is not a library this platform can open. -/
  | notLoadable
  /-- The grammar is of an ABI the parsing library does not speak. -/
  | unsupportedAbi
  /-- The library exports no symbol of that name. -/
  | missingSymbol
  /-- The syntax service loads no grammar at run time. -/
  | unsupported
  deriving DecidableEq, Repr, Inhabited

/-- What a refusal says, as a sentence for a person. -/
def RegistrationRefusal.describe : RegistrationRefusal → String
  | .notFound => "no file is at the grammar's path"
  | .notLoadable => "the file is not a library this platform can open"
  | .unsupportedAbi => "the grammar is of an ABI the parsing library does not speak"
  | .missingSymbol => "the library exports no such symbol"
  | .unsupported => "this editor loads no grammar at run time"

/-- Why a registration did not register: refused by the syntax service, or
failed on the way to it. -/
inductive GrammarError where
  /-- The syntax service refused it. -/
  | refused (refusal : RegistrationRefusal)
  /-- Anything else; `detail` says what. -/
  | failed (detail : String)
  deriving DecidableEq, Repr

/-- What an error says, as a sentence for a person. -/
def GrammarError.describe : GrammarError → String
  | .refused refusal => s!"the grammar was refused: {refusal.describe}"
  | .failed detail => s!"the grammar's registration failed: {detail}"

/-- What a job may ask of the syntax service's grammars. -/
inductive GrammarRequest where
  /-- Register the grammar `source` names, and answer the name it is
  registered under. -/
  | register (source : GrammarSource)
  deriving DecidableEq, Repr

/-- The type of the reply to each grammar request: the registered name, or
why not. -/
def GrammarRequest.Reply : GrammarRequest → Type
  | .register _ => Except GrammarError String

/-- The reply of a refused request. -/
def GrammarRequest.refused : (request : GrammarRequest) → GrammarError → request.Reply
  | .register _, error => .error error

end Editor
