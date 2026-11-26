import Editor.Language
import Editor.Language.Grammar
import Editor.Language.Grammar.Answer
import ModelTest.Check

/-!
# Model tests: `Editor/Language/Grammar.lean`

The model tests of `Editor/Language/Grammar.lean`:
`grammarDeclarationChecks`. The root module `ModelTest` runs them; its module
doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The checks of a grammar declaration and its pure rules
(`Editor/Language/Grammar.lean`): the defaults, the problems, a later
owner's declaration over an earlier's, which tree a buffer's language
resolves to, and the sentences a refusal is said in. -/
def grammarDeclarationChecks : List Check :=
  [{  name :=
        "a declaration given a name and a library alone has the symbol tree_sitter_<name>, no policy and the query directory queries/ in the library's directory"
      run :=
        let ini := Language.Grammar.declare "ini" "/opt/grammars/libtree-sitter-ini.so"
        pure
          (ini ==
            { name := "ini"
              source :=
                { library := "/opt/grammars/libtree-sitter-ini.so", symbol := "tree_sitter_ini"
                  policy := none }
              queries := "/opt/grammars/queries" }) },
    { name := "a declaration given a symbol, a query directory and a policy keeps them"
      run :=
        let conf :=
          Language.Grammar.declare "conf" "/opt/grammars/libconf.so" (symbol := "conf")
            (queries := "/other/conf-queries") (policy := ReparsePolicy.incremental)
        pure
          (conf ==
            { name := "conf"
              source :=
                { library := "/opt/grammars/libconf.so", symbol := "conf"
                  policy := some .incremental }
              queries := "/other/conf-queries" }) },
    { name :=
        "a declaration whose symbol registers another name, or whose library or query directory is relative, has a problem that names it; one whose bare symbol is its name has none"
      run :=
        let otherName :=
          Language.Grammar.declare "c-sharp" "/g/libcs.so" (symbol := "tree_sitter_c_sharp")
        let relativeLibrary := Language.Grammar.declare "ini" "grammars/libini.so"
        let relativeQueries := Language.Grammar.declare "ini" "/g/libini.so" (queries := "queries")
        let bare := Language.Grammar.declare "ini" "/g/libini.so" (symbol := "ini")
        pure
          (otherName.problem? ==
              some
                "the grammar `c-sharp`'s symbol `tree_sitter_c_sharp` registers the grammar `c_sharp`: a grammar is declared under the name its symbol registers" &&
            relativeLibrary.problem? ==
              some "the grammar `ini`'s library `grammars/libini.so` is not an absolute path" &&
            relativeQueries.problem? ==
              some "the grammar `ini`'s query directory `queries` is not an absolute path" &&
            bare.problem? == none &&
            (Language.Grammar.declare "ini" "/g/libini.so").problem? == none) },
    { name := "a later owner's declaration of a name replaces an earlier owner's"
      run :=
        let earlierIni := Language.Grammar.declare "ini" "/a/libini.so"
        let conf := Language.Grammar.declare "conf" "/a/libconf.so"
        let laterIni := Language.Grammar.declare "ini" "/b/libini.so"
        pure (Language.Grammar.over [laterIni] [earlierIni, conf] == [laterIni, conf]) },
    { name :=
        "a grammar no declaration names keeps the entry's tree; a declared one with no answer of this generation has no tree; registered, it takes the read queries where the entry gives none and keeps the entry's own; refused and still known it keeps the entry's tree; refused and unknown it has none; an answer of another generation counts as none"
      run :=
        let declared := [Language.Grammar.declare "ini" "/g/libini.so"]
        let tree : Mode.SyntaxTree := { grammar := "ini", indents := some "(own) @indent" }
        let read : Language.Grammar.Queries :=
          { highlights := some "(number) @number", indents := some "(file) @indent"
            injections := none }
        let answered (answer : Language.Grammar.Answer) : Language.Grammar.Answers :=
          { generation := 2, answers := #[("ini", answer)] }
        let resolve (answers : Language.Grammar.Answers) (generation : Nat := 2) :=
          Language.Grammar.treeOf declared answers generation tree
        pure
          (Language.Grammar.treeOf declared {} 2 { grammar := "toml" } ==
              some { grammar := "toml" } &&
            resolve {} == none &&
            resolve (answered (.registered read)) ==
              some
                { grammar := "ini", highlights := some "(number) @number"
                  indents := some "(own) @indent" } &&
            resolve (answered (.refused (.refused .notFound) true)) == some tree &&
            resolve (answered (.refused (.refused .notFound) false)) == none &&
            resolve (answered (.registered read)) (generation := 3) == none) },
    { name :=
        "a refusal's sentence names the grammar, the error and what stays: the compiled-in grammar, the grammar registered before, or no syntax tree for its languages; a query file's refusal names the grammar, the file and the error"
      run :=
        let error : GrammarError := .refused .notFound
        let ini := Language.Grammar.declare "ini" "/g/libini.so"
        pure
          (Language.Grammar.said "lean" error (kept := true) (registeredBefore := false) ==
              s!"grammar `lean`: {error.describe}, so the compiled-in grammar stays" &&
            Language.Grammar.said "ini" error (kept := true) (registeredBefore := true) ==
              s!"grammar `ini`: {error.describe}, so the grammar registered before stays" &&
            Language.Grammar.said "ini" error (kept := false) (registeredBefore := false) ==
              s!"grammar `ini`: {error.describe}, so its languages have no syntax tree" &&
            Language.Grammar.unread ini "indents.scm" .denied ==
              s!"grammar `ini`: /g/queries/indents.scm: {FileError.denied.describe}") }]

end ModelTest
