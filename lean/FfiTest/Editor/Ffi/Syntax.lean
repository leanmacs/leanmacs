import Editor.Ffi.Document
import Editor.Ffi.Files
import Editor.Ffi.Snapshot
import Editor.Ffi.Syntax
import FfiTest.Check
import FfiTest.Support.Files

/-!
# FFI tests: `Editor/Ffi/Syntax.lean`

The tests of `Editor/Ffi/Syntax.lean`: `syntaxChecks`. The root module `FfiTest`
runs them, and each list's own doc says what it checks.
-/

namespace FfiTest

/-- A document of `text`, a snapshot of it, attached to `grammar` in the
library's syntax service, once the tree of the snapshot is delivered; or
`none`. The document is returned so that the caller keeps it alive: Lean
frees an object after its last use, and a document freed is detached, so a
caller uses the document after its last question of the service. -/
def parsedSnapshot (text grammar : String) :
    IO (Option (Editor.Ffi.Document × Editor.Ffi.Snapshot)) := do
  let document ← Editor.Ffi.Document.new text
  let snapshot ← document.snapshot
  unless (← Editor.Ffi.syntaxAttach snapshot grammar) matches .ok () do
    return none
  unless ← Editor.Ffi.syntaxSettle snapshot patience do
    return none
  return some (document, snapshot)

/-- A query of `grammar` compiled in the library, or `none`. -/
def syntaxQuery (grammar source : String) : IO (Option Editor.Ffi.SyntaxQuery) := do
  return (← Editor.Ffi.SyntaxQuery.new grammar source).toOption

/-- The capture names of a query of `grammar` compiled in the library, and
how many queries the library holds while it is held; `none` when it is not
made. The query is dropped on return. -/
def namesWhileHeld (grammar source : String) : IO (Option (Array String × UInt64)) := do
  let some query ← syntaxQuery grammar source | return none
  let held ← Editor.Ffi.SyntaxQuery.live
  return some (← query.captureNames, held)

/-- The checks of the syntax service's bindings: a list of strings out, a
query as a handle with its refusals as a status, a tag and an offset, and
captures as words with their refusals as statuses. What is parsed and what a
query answers are the library's rules; these pin that each request, its
answer and each refusal cross. -/
def syntaxChecks (_ : Unit) : List Check :=
  [{  name := "the grammars the library has cross as a list of strings"
      run := do
        let grammars ← Editor.Ffi.syntaxGrammars
        return ["json", "rust", "markdown", "toml", "lean"].all grammars.contains },
    { name :=
        "a query crosses as a handle, with its capture names as a list of strings, and is freed when the last reference to it goes"
      run := do
        let before ← Editor.Ffi.SyntaxQuery.live
        let names ← namesWhileHeld "json" "(pair key: (string) @key value: (_) @value) @pair"
        return names == some (#["key", "value", "pair"], before + 1) &&
            (← Editor.Ffi.SyntaxQuery.live) == before },
    { name :=
        "a query refused crosses with the library's tag of why and the byte offset it found it at, and one of a grammar the library lacks as that"
      run := do
        let refused ← Editor.Ffi.SyntaxQuery.new "json" "(object) @o\n(no_such_kind) @x"
        let field ← Editor.Ffi.SyntaxQuery.new "json" "(pair nope: (string)) @x"
        let malformed ← Editor.Ffi.SyntaxQuery.new "json" "(("
        let unknown ← Editor.Ffi.SyntaxQuery.new "cobol" "(x) @x"
        return (match refused with
            | .error (.refused 1 13) => true
            | _ => false) &&
            (match field with
            | .error (.refused 2 _) => true
            | _ => false) &&
            (match malformed with
            | .error (.refused 0 _) => true
            | _ => false) &&
            (match unknown with
            | .error .unknownGrammar => true
            | _ => false) },
    { name :=
        "captures cross as words, four a capture: a Rust function's name, by its pattern, its capture and its range"
      run := do
        let some (document, snapshot) ←
          parsedSnapshot "fn one() {}\nfn two() {}\n" "rust" | return false
        let some query ←
          syntaxQuery "rust" "(function_item name: (identifier) @name) @function" | return false
        let found ← Editor.Ffi.syntaxCaptures snapshot query 0 24
        let some names ←
          (Editor.Ffi.syntaxCaptures snapshot query 15 16).map (·.toOption) | return false
        let kept ← document.read
        return found.toOption ==
              some
                #[{ pattern := 0, capture := 1, start := 0, stop := 11 },
                  { pattern := 0, capture := 0, start := 3, stop := 6 },
                  { pattern := 0, capture := 1, start := 12, stop := 23 },
                  { pattern := 0, capture := 0, start := 15, stop := 18 }] &&
            names.size == 2 &&
            !kept.isEmpty },
    { name :=
        "each refusal of captures crosses as its status: a text not attached, a tree not delivered of the snapshot's revision, a query of another grammar and a range that is not two positions in order"
      run := do
        let some (document, snapshot) ← parsedSnapshot "fn one() {}\n" "rust" | return false
        let some rust ← syntaxQuery "rust" "(identifier) @id" | return false
        let some json ← syntaxQuery "json" "(number) @n" | return false
        let other ← (← Editor.Ffi.Document.new "fn x() {}").snapshot
        let notAttached ← Editor.Ffi.syntaxCaptures other rust 0 2
        let wrongGrammar ← Editor.Ffi.syntaxCaptures snapshot json 0 2
        let badRange ← Editor.Ffi.syntaxCaptures snapshot rust 5 2
        let pastTheEnd ← Editor.Ffi.syntaxCaptures snapshot rust 0 100
        -- An edit the snapshot taken before it is not of: once the tree of
        -- the edit is delivered, the earlier snapshot has none.
        unless (← document.replace 0 0 "fn zero() {}\n") == .done do
          return false
        unless ← Editor.Ffi.syntaxSettle (← document.snapshot) patience do
          return false
        let notParsed ← Editor.Ffi.syntaxCaptures snapshot rust 0 2
        -- The document is read here, so it is alive until now: a document
        -- freed is detached.
        let kept ← document.read
        return !kept.isEmpty && notAttached matches .error .notAttached &&
            wrongGrammar matches .error .wrongGrammar &&
            badRange matches .error .badRange &&
            pastTheEnd matches .error .badRange &&
            notParsed matches .error .notParsed },
    { name :=
        "a shipped query crosses as its source, and its refusals as their statuses: a grammar the library lacks and a kind it has no tag for"
      run := do
        let shipped ← Editor.Ffi.syntaxShippedQuery "json" 0
        let unknown ← Editor.Ffi.syntaxShippedQuery "cobol" 0
        let noKind ← Editor.Ffi.syntaxShippedQuery "json" 9
        let compiles ←
          match shipped with
          | .ok source =>
            do
              pure (← Editor.Ffi.SyntaxQuery.new "json" source).toBool
          | .error _ =>
            pure false
        return compiles && unknown matches .error .unknownGrammar &&
            noKind matches .error .noShippedQuery },
    { name :=
        "faces cross as a list of strings in, and each refusal of a highlight as its status: a text not attached, a query of another grammar and faces not one for each capture name"
      run := do
        let some (document, snapshot) ← parsedSnapshot "[1, true]" "json" | return false
        let some json ← syntaxQuery "json" "(number) @number\n(true) @constant" | return false
        let some rust ← syntaxQuery "rust" "(identifier) @id" | return false
        let other ← (← Editor.Ffi.Document.new "[2]").snapshot
        let notAttached ← Editor.Ffi.syntaxHighlight other json #["syntax.number", ""]
        let wrongGrammar ← Editor.Ffi.syntaxHighlight snapshot rust #["syntax.variable"]
        let badFaces ← Editor.Ffi.syntaxHighlight snapshot json #["syntax.number"]
        let highlighted ← Editor.Ffi.syntaxHighlight snapshot json #["syntax.number", "é漢"]
        let kept ← document.read
        return !kept.isEmpty && notAttached matches .error .notAttached &&
            wrongGrammar matches .error .wrongGrammar &&
            badFaces matches .error .badFaces &&
            highlighted matches .ok () },
    { name :=
        "an injections query and a language cross, the language's injections query as a handle or none, and each refusal as its status: a text not attached, a query of another grammar and faces not one for each capture name"
      run := do
        let some (document, snapshot) ←
          parsedSnapshot "# Title\n\n```rust\nfn f() {}\n```\n" "markdown" | return false
        let some markdown ←
          syntaxQuery "markdown"
              "(fenced_code_block (info_string (language) @injection.language) (code_fence_content) @injection.content)" | return false
        let some rust ← syntaxQuery "rust" "(identifier) @id" | return false
        let some json ← syntaxQuery "json" "(number) @n" | return false
        let other ← (← Editor.Ffi.Document.new "x").snapshot
        let notAttached ← Editor.Ffi.syntaxInject other markdown
        let wrongGrammar ← Editor.Ffi.syntaxInject snapshot rust
        let injected ← Editor.Ffi.syntaxInject snapshot markdown
        let languageNotAttached ←
          Editor.Ffi.syntaxInjectLanguage other "rust" rust #["syntax.variable"] none
        let languageWrongGrammar ←
          Editor.Ffi.syntaxInjectLanguage snapshot "rust" rust #["syntax.variable"] (some json)
        let badFaces ← Editor.Ffi.syntaxInjectLanguage snapshot "rust" rust #[] none
        let language ←
          Editor.Ffi.syntaxInjectLanguage snapshot "rust" rust #["syntax.variable"] (some rust)
        let plain ← Editor.Ffi.syntaxInjectLanguage snapshot "json" json #["é漢"] none
        let kept ← document.read
        return !kept.isEmpty && notAttached matches .error .notAttached &&
            wrongGrammar matches .error .wrongGrammar &&
            injected matches .ok () &&
            languageNotAttached matches .error .notAttached &&
            languageWrongGrammar matches .error .wrongGrammar &&
            badFaces matches .error .badFaces &&
            language matches .ok () &&
            plain matches .ok () },
    { name :=
        "a kept query crosses by its kind's tag, its names as a list of strings and its captures as words, and each refusal as its status: nothing kept, a query of another grammar, a range not two positions in order, a text not attached and a tree not delivered of the snapshot's revision; a kind with no tag is an IO error"
      run := do
        let some (document, snapshot) ← parsedSnapshot "fn one() {}\n" "rust" | return false
        let some query ←
          syntaxQuery "rust" "(function_item name: (identifier) @name) @function" | return false
        let some json ← syntaxQuery "json" "(number) @n" | return false
        let nothing ← Editor.Ffi.syntaxKeptCaptures snapshot 2 0 12
        let nothingNamed ← Editor.Ffi.syntaxKeptNames snapshot 2
        let wrongGrammar ← Editor.Ffi.syntaxKeep snapshot 2 json
        let kept ← Editor.Ffi.syntaxKeep snapshot 2 query
        let names ← Editor.Ffi.syntaxKeptNames snapshot 2
        let captures ← Editor.Ffi.syntaxKeptCaptures snapshot 2 0 12
        let badRange ← Editor.Ffi.syntaxKeptCaptures snapshot 2 5 2
        let otherKind ← Editor.Ffi.syntaxKeptCaptures snapshot 3 0 12
        let other ← (← Editor.Ffi.Document.new "x").snapshot
        let notAttached ← Editor.Ffi.syntaxKeptCaptures other 2 0 1
        let noTag ←
          try
            discard (Editor.Ffi.syntaxKeep snapshot 9 query)
            pure false
          catch _ =>
            pure true
        unless (← document.replace 0 0 "fn zero() {}\n") == .done do
          return false
        unless ← Editor.Ffi.syntaxSettle (← document.snapshot) patience do
          return false
        let notParsed ← Editor.Ffi.syntaxKeptCaptures snapshot 2 0 12
        let read ← document.read
        return !read.isEmpty && nothing matches .error .noQuery &&
            nothingNamed matches .error .noQuery &&
            wrongGrammar matches .error .wrongGrammar &&
            kept matches .ok () &&
            names.toOption == some #["name", "function"] &&
            captures.toOption ==
              some
                #[{ pattern := 0, capture := 1, start := 0, stop := 11 },
                  { pattern := 0, capture := 0, start := 3, stop := 6 }] &&
            badRange matches .error .badRange &&
            otherKind matches .error .noQuery &&
            notAttached matches .error .notAttached &&
            noTag &&
            notParsed matches .error .notParsed },
    { name :=
        "a document is attached and detached through a snapshot of it, and one of a grammar the library lacks is refused"
      run := do
        let document ← Editor.Ffi.Document.new "[1]"
        let snapshot ← document.snapshot
        let unknown ← Editor.Ffi.syntaxAttach snapshot "cobol"
        let attached ← Editor.Ffi.syntaxAttach snapshot "json"
        let first ← Editor.Ffi.syntaxDetach snapshot
        let second ← Editor.Ffi.syntaxDetach snapshot
        let kept ← document.read
        return kept == "[1]" && unknown matches .error .unknownGrammar && attached matches .ok () &&
            first &&
            !second },
    { name := "the text of a file the file service loaded is of no document, and is refused as that"
      run :=
        inOwnDirectory fun directory => do
          let path := directory / "loaded.json"
          IO.FS.writeFile path "[1]"
          let some (.loaded snapshot _ _ _) ← loadResult 1090 path 100 | return false
          return (← Editor.Ffi.syntaxAttach snapshot "json") matches .error .noDocument }]

end FfiTest
