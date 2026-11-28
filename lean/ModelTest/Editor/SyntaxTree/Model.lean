import Editor.Program
import Editor.Scene
import Editor.SyntaxTree
import Editor.SyntaxTree.Contract
import Editor.SyntaxTree.Model
import Editor.SyntaxTree.Model.Json
import Editor.SyntaxTree.Model.Query
import Editor.SyntaxTree.Registration
import Editor.SyntaxTree.Registration.Model
import Editor.Test.Models
import Editor.Text
import ModelTest.Check

/-!
# Model tests: `Editor/SyntaxTree/Model.lean`

The model tests of `Editor/SyntaxTree/Model.lean`: `syntaxTreeChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The model, but a question of captures in a range answers the whole
text's: a model that breaks the range rule. -/
def wholeRange : (request : SyntaxTreeRequest) → SyntaxTreeModel → request.Reply × SyntaxTreeModel
  | .captures snapshot query _ _, model =>
    let length := ((model.text? snapshot).map (·.utf8ByteSize)).getD 0
    SyntaxTreeModel.handle (.captures snapshot query 0 length) model
  | request, model => SyntaxTreeModel.handle request model

/-- The flat tree the model parses `text` to, each node as its kind, its
field, its depth and its range. -/
def jsonShape (text : String) : Array (String × Option String × Nat × Nat × Nat) :=
  (SyntaxTreeModel.Json.parse text).flatten.map fun node =>
    (node.kind, node.field, node.depth, node.start, node.stop)

/-- Whether `source` is refused by the model's query subset as unsupported. -/
def unsupportedQuery (source : String) : Bool :=
  match SyntaxTreeModel.Query.compile source with
  | .error (.unsupported, _) => true
  | _ => false

/-- The checks of the syntax tree interface's model
(`Editor/SyntaxTree/Model.lean`): what only the model shows, and the
contract (`Editor/SyntaxTree/Contract.lean`) seen to report a model that
breaks the range rule. -/
def syntaxTreeChecks : List Check :=
  [{  name :=
        "the JSON model parses a small object node by node as the library's grammar does: the root, the object and its braces, a pair with its key and value at their fields, and each string's quotes and content"
      run :=
        pure <|
          jsonShape "{\"k\": \"v\"}" ==
            #[("document", none, 0, 0, 10), ("object", none, 1, 0, 10), ("{", none, 2, 0, 1),
              ("pair", none, 2, 1, 9), ("string", some "key", 3, 1, 4), ("\"", none, 4, 1, 2),
              ("string_content", none, 4, 2, 3), ("\"", none, 4, 3, 4), (":", none, 3, 4, 5),
              ("string", some "value", 3, 6, 9), ("\"", none, 4, 6, 7),
              ("string_content", none, 4, 7, 8), ("\"", none, 4, 8, 9), ("}", none, 2, 9, 10)] },
    { name :=
        "the JSON model's root starts after the blanks that lead the text, and at its end when it has no value"
      run :=
        pure <|
          jsonShape "" == #[("document", none, 0, 0, 0)] &&
            jsonShape "   " == #[("document", none, 0, 3, 3)] &&
            jsonShape " 1 " == #[("document", none, 0, 1, 3), ("number", none, 1, 1, 2)] &&
            jsonShape "-0.5e-3" == #[("document", none, 0, 0, 7), ("number", none, 1, 0, 7)] },
    { name :=
        "a text outside the JSON model's subset parses to the root over one ERROR node, from its first character that is not a blank"
      run :=
        pure <|
          jsonShape "[1,]" == #[("document", none, 0, 0, 4), ("ERROR", none, 1, 0, 4)] &&
            jsonShape " \"a\\nb\"" == #[("document", none, 0, 1, 7), ("ERROR", none, 1, 1, 7)] },
    { name :=
        "the model's query subset refuses a quantifier, an alternation, an anchor, a negated field, a predicate and a grouping as unsupported, and accepts what it implements"
      run :=
        pure <|
          unsupportedQuery "(number)* @n" && unsupportedQuery "(array (number)+ @n)" &&
            unsupportedQuery "[(true) (false)] @b" &&
            unsupportedQuery "(array . (number) @n)" &&
            unsupportedQuery "(pair !key) @p" &&
            unsupportedQuery "((number) @n (#eq? @n \"1\"))" &&
            unsupportedQuery "((number) @n (string) @s)" &&
            (SyntaxTreeModel.Query.compile
                "(pair key: (string) @k value: _ @v) ; c\n\",\" @c").toBool },
    { name :=
        "the syntax tree contract reports a model that answers a range with the whole text's captures, by its properties of ranges and by none of the whole text"
      run := do
        let broken ← syntaxTreeBroken wholeRange
        return broken.any (·.startsWith "a range answers the whole text's rows that are in it") &&
            broken.all (·.startsWith "a range ") },
    { name := "the model records the refresh delay it is handed, and answers nothing else for it"
      run :=
        pure <|
          let (model, ids) := syntaxTreeModelOf #["[1]"]
          let snapshot := ids[0]?.getD ⟨0⟩
          let program : SyntaxTreeM (Array SyntaxTree.Capture) := do
            SyntaxTree.attach snapshot "json"
            SyntaxTree.refreshAfter 250
            let query ← SyntaxTree.compile "json" "(number) @n"
            SyntaxTree.captures snapshot query 0 3
          match SyntaxTreeM.runModel program model with
          | (.ok found, after) => after.refreshAfter == some 250 && found.size == 1
          | _ => false },
    { name :=
        "a model whose trees a test says are not delivered refuses captures and capturesOf with notParsed, after the range check, and answers both once they are"
      run :=
        pure <|
          let (model, ids) := syntaxTreeModelOf #["[1]"]
          let snapshot := ids[0]?.getD ⟨0⟩
          let program : SyntaxTreeM Bool := do
            SyntaxTree.attach snapshot "json"
            let query ← SyntaxTree.compile "json" "(number) @n"
            SyntaxTree.keep snapshot .indents query
            return (←
                  SyntaxTreeContract.refusedWith .notParsed
                      (SyntaxTree.captures snapshot query 0 3)) &&
                (←
                  SyntaxTreeContract.refusedWith .notParsed
                      (SyntaxTree.capturesOf snapshot .indents 0 3)) &&
                (←
                  SyntaxTreeContract.refusedWith .badRange
                      (SyntaxTree.capturesOf snapshot .indents 0 9)) &&
                (←
                  SyntaxTreeContract.refusedWith .noQuery
                      (SyntaxTree.capturesOf snapshot .textObjects 0 3))
          let delivered : SyntaxTreeM Nat := do
            SyntaxTree.attach snapshot "json"
            let query ← SyntaxTree.compile "json" "(number) @n"
            SyntaxTree.keep snapshot .indents query
            return (← SyntaxTree.captures snapshot query 0 3).size +
                (← SyntaxTree.capturesOf snapshot .indents 0 3).captures.size
          (SyntaxTreeM.runModel program { model with delivered := false }).1 matches .ok true &&
            (SyntaxTreeM.runModel delivered model).1 matches .ok 2 },
    { name :=
        "a default syntax tree model lists no grammar and refuses json as unknown; given the test grammars it lists the six registered names, attaches and compiles for each and ships no query for any; given another registry it lists that alone"
      run :=
        pure <|
          let (model, ids) := syntaxTreeModelOf #["[1]"]
          let snapshot := ids[0]?.getD ⟨0⟩
          let bare := { model with registry := {} }
          let python : GrammarRegistry :=
            {
              registered :=
                #[("python", { library := "/lib/grammars.so", symbol := "tree_sitter_python" },
                    .whole)] }
          let listsNone : SyntaxTreeM Bool := do
            let names ← SyntaxTree.grammars
            return names.isEmpty &&
                (←
                  SyntaxTreeContract.refusedWith .unknownGrammar
                      (SyntaxTree.attach snapshot "json"))
          let registered : SyntaxTreeM Bool := do
            let names ← SyntaxTree.grammars
            SyntaxTree.attach snapshot "rust"
            let query ← SyntaxTree.compile "rust" "(number) @n"
            let found ← SyntaxTree.captures snapshot query 0 3
            let shipsNone ←
              names.allM fun name =>
                  SyntaxTreeContract.refusedWith .noShippedQuery
                    (SyntaxTree.shippedQuery name .highlights)
            return names == GrammarRegistry.testGrammarNames.map (·.1) && found.size == 1 &&
                shipsNone
          let pythonAlone : SyntaxTreeM Bool := do
            let names ← SyntaxTree.grammars
            SyntaxTree.attach snapshot "python"
            return names == #["python"] &&
                (←
                  SyntaxTreeContract.refusedWith .noShippedQuery
                      (SyntaxTree.shippedQuery "python" .highlights))
          (SyntaxTreeM.runModel listsNone bare).1 matches .ok true &&
            (SyntaxTreeM.runModel registered model).1 matches .ok true &&
            (SyntaxTreeM.runModel pythonAlone { bare with registry := python }).1 matches
              .ok true },
    { name :=
        "a syntax tree model given json and lean as compiled in lists both, attaches and compiles for each and ships its highlights for each; a registration of either overrides it and ships no query for it"
      run :=
        -- The explicit opt-in to compiled-in names: the core's shipped-query
        -- fallback and its override rule still read them, until phase 4 of
        -- the roadmap `shipped-grammars-package` removes both and this check.
        pure <|
          let (model, ids) := syntaxTreeModelOf #["[1]"]
          let snapshot := ids[0]?.getD ⟨0⟩
          let compiled :=
            { model with
              compiled := #["json", "lean"], registry := {} }
          let leanRegistered : GrammarRegistry :=
            {
              registered :=
                #[("lean", { library := "/lib/lean.so", symbol := "tree_sitter_lean" }, .whole)] }
          let jsonRegistered : GrammarRegistry :=
            {
              registered :=
                #[("json", { library := "/lib/json.so", symbol := "tree_sitter_json" }, .whole)] }
          let both : SyntaxTreeM Bool := do
            let names ← SyntaxTree.grammars
            SyntaxTree.attach snapshot "lean"
            let query ← SyntaxTree.compile "lean" "(number) @n"
            let found ← SyntaxTree.captures snapshot query 0 3
            discard (SyntaxTree.compile "json" "(number) @n")
            let leanShips ← SyntaxTree.shippedQuery "lean" .highlights
            let jsonShips ← SyntaxTree.shippedQuery "json" .highlights
            return names == #["json", "lean"] && found.size == 1 &&
                leanShips == SyntaxTreeModel.highlights &&
                jsonShips == SyntaxTreeModel.highlights
          let overridden (name : String) : SyntaxTreeM Bool := do
            let names ← SyntaxTree.grammars
            SyntaxTree.attach snapshot name
            return names == #["json", "lean"] &&
                (←
                  SyntaxTreeContract.refusedWith .noShippedQuery
                      (SyntaxTree.shippedQuery name .highlights))
          (SyntaxTreeM.runModel both compiled).1 matches .ok true &&
            (SyntaxTreeM.runModel (overridden "lean")
                  { compiled with registry := leanRegistered }).1 matches
              .ok true &&
            (SyntaxTreeM.runModel (overridden "json")
                  { compiled with registry := jsonRegistered }).1 matches
              .ok true },
    { name := "every property of the syntax tree contract holds of the model"
      run := return (← syntaxTreeBroken SyntaxTreeModel.handle).isEmpty }]

end ModelTest
