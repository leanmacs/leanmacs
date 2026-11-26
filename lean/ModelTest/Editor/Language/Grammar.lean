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
            { name := "ini", library := .single "/opt/grammars/libtree-sitter-ini.so"
              symbol := "tree_sitter_ini", policy := none, queries := "/opt/grammars/queries" }) },
    { name := "a declaration given a symbol, a query directory and a policy keeps them"
      run :=
        let conf :=
          Language.Grammar.declare "conf" "/opt/grammars/libconf.so" (symbol := "conf") (queries :=
            "/other/conf-queries") (policy := ReparsePolicy.incremental)
        pure
          (conf ==
            { name := "conf", library := .single "/opt/grammars/libconf.so", symbol := "conf"
              policy := some .incremental, queries := "/other/conf-queries" }) },
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
        "a grammar no declaration names keeps the entry's tree; a declared one with no answer of this generation has no tree; registered, it takes the read queries where the entry gives none and keeps the entry's own; refused and still known it keeps the entry's tree, with the queries read at its last registration when this process registered it; refused and unknown it has none; an answer of another generation counts as none"
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
            resolve
                { answered (.refused (.refused .notFound) true) with
                  registered := #[("ini", read)] } ==
              some
                { grammar := "ini", highlights := some "(number) @number"
                  indents := some "(own) @indent" } &&
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
              s!"grammar `ini`: /g/queries/indents.scm: {FileError.denied.describe}") },
    { name :=
        "platformOf maps arm64-apple-darwin24.6.0, x86_64-apple-darwin, aarch64-unknown-linux-gnu and x86_64-unknown-linux-gnu to darwin-aarch64, darwin-x86_64, linux-aarch64 and linux-x86_64, and keeps any other triple"
      run :=
        pure
          (Language.Grammar.platformOf "arm64-apple-darwin24.6.0" == "darwin-aarch64" &&
            Language.Grammar.platformOf "x86_64-apple-darwin" == "darwin-x86_64" &&
            Language.Grammar.platformOf "aarch64-unknown-linux-gnu" == "linux-aarch64" &&
            Language.Grammar.platformOf "x86_64-unknown-linux-gnu" == "linux-x86_64" &&
            Language.Grammar.platformOf "riscv64-unknown-linux-gnu" ==
              "riscv64-unknown-linux-gnu" &&
            Language.Grammar.platformOf "x86_64-pc-windows-msvc" == "x86_64-pc-windows-msvc") },
    { name :=
        "a per-platform declaration gives the source of the listed platform's library with its symbol and policy, and none for an unlisted platform; a single declaration gives its library on every platform"
      run :=
        let perPlatform :=
          Language.Grammar.declarePerPlatform "ini"
            [("darwin-aarch64", "/g/darwin-aarch64/libini.dylib"),
              ("linux-x86_64", "/g/linux-x86_64/libini.so")]
            "/g/queries" (policy := ReparsePolicy.incremental)
        let single := Language.Grammar.declare "ini" "/g/libini.so"
        pure
          (perPlatform.sourceOn "darwin-aarch64" ==
              some
                { library := "/g/darwin-aarch64/libini.dylib", symbol := "tree_sitter_ini"
                  policy := some .incremental } &&
            perPlatform.sourceOn "linux-x86_64" ==
              some
                { library := "/g/linux-x86_64/libini.so", symbol := "tree_sitter_ini"
                  policy := some .incremental } &&
            perPlatform.sourceOn "linux-riscv64" == none &&
            perPlatform.queries == "/g/queries" &&
            perPlatform.problem? == none &&
            single.sourceOn "darwin-aarch64" ==
              some { library := "/g/libini.so", symbol := "tree_sitter_ini", policy := none } &&
            single.sourceOn "linux-riscv64" ==
              some { library := "/g/libini.so", symbol := "tree_sitter_ini", policy := none }) },
    { name :=
        "a per-platform declaration with no path, a platform listed twice, or a relative path has a problem that names it"
      run :=
        let empty := Language.Grammar.declarePerPlatform "ini" [] "/g/queries"
        let twice :=
          Language.Grammar.declarePerPlatform "ini"
            [("darwin-aarch64", "/g/a/libini.dylib"), ("darwin-aarch64", "/g/b/libini.dylib")]
            "/g/queries"
        let relative :=
          Language.Grammar.declarePerPlatform "ini"
            [("darwin-aarch64", "/g/a/libini.dylib"), ("linux-x86_64", "linux/libini.so")]
            "/g/queries"
        let relativeQueries :=
          Language.Grammar.declarePerPlatform "ini" [("darwin-aarch64", "/g/a/libini.dylib")]
            "queries"
        pure
          (empty.problem? == some "the grammar `ini` declares a library for no platform" &&
            twice.problem? ==
              some "the grammar `ini` declares a library for the platform `darwin-aarch64` twice" &&
            relative.problem? ==
              some
                "the grammar `ini`'s library `linux/libini.so` for the platform `linux-x86_64` is not an absolute path" &&
            relativeQueries.problem? ==
              some "the grammar `ini`'s query directory `queries` is not an absolute path") },
    { name :=
        "within? keeps a relative path that stays inside, normalised, and refuses an absolute one and one whose .. climbs out"
      run :=
        pure
          (Language.Grammar.within? "darwin-aarch64/libini.dylib" ==
              some "darwin-aarch64/libini.dylib" &&
            Language.Grammar.within? "./a/../queries/" == some "queries" &&
            Language.Grammar.within? "." == some "." &&
            Language.Grammar.within? "../outside.dylib" == none &&
            Language.Grammar.within? "a/../../outside.dylib" == none &&
            Language.Grammar.within? "/abs/libini.so" == none) }]

end ModelTest
