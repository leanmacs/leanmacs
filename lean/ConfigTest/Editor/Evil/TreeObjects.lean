import ConfigTest.Check
import ConfigTest.Support.Hosts
import ConfigTest.Support.Keys
import ConfigTest.Support.Lines
import ConfigTest.Support.Syntax
import Editor.File.Model
import Editor.Headless

/-!
# Config tests: `Editor/Evil/TreeObjects.lean`

The tests of `Editor/Evil/TreeObjects.lean`: `treeObjectChecks`, through a host
of the Vim scheme that ships over the real syntax tree binding. The root module
`ConfigTest` runs them; its module doc says what each shows.
-/

namespace ConfigTest

/-- A config whose `setup` defines the mode `rust-test`, whose text is
parsed with the grammar `rust` and drawn by the shipped default, and the
command `rust-buffer`, which puts `rustObjectsText` in the scratch buffer's
text, places the cursor inside the method's body, at `let`, and only then
makes `rust-test` its major mode, so the text is attached at its last
revision. -/
def rustObjectsConfig : String :=
  "def rustText : String := " ++ rustObjectsText.quote ++
    "

def rustBuffer : EditorM Unit := do
  let text : TextId := ⟨0⟩
  text.insert 0 rustText
  let cursor := ((rustText.splitOn \"let x\").headD \"\").utf8ByteSize
  discard <| (⟨0⟩ : ViewId).select { ranges := #[⟨cursor, cursor⟩], shape := .inclusive }
  discard <| (⟨0⟩ : ViewId).setMajorMode \"rust-test\"

def setup : SetupM Unit := do
  defineMode { name := \"rust-test\", syntaxTree := some { grammar := \"rust\" } }
  command \"rust-buffer\" rustBuffer
"

/-- The checks of the syntax tree's text objects through a host of the Vim
scheme that ships (`withVimHost`), with the real elaborator, the real text
binding and the library's syntax service: what keys select and delete in a
Rust buffer. Which node an object is, is `Editor/Evil/TreeObjects.lean`'s,
pinned by `ModelTest.treeObjectRuleChecks` and `ModelTest.evilObjectChecks`
and, over the library, by `ContractTest`. -/
def treeObjectChecks (context : Context) : List Check :=
  [{  name :=
        "in a Rust buffer v a f selects the enclosing function, from its fn through its closing brace, through the host's loop and the library's syntax tree; and <Escape> d a f then deletes it, its lines whole"
      run :=
        -- Seen to bite once by hand: with `a-function` taken out of
        -- `Evil.objects`, `v a f` leaves the cursor's one cell selected.
        withVimHost context [("init.lean", rustObjectsConfig)] fun session => do
          session.ask [.reload]
          session.ask [.run "rust-buffer"]
          let before := lastViewLine (← session.sceneLines)
          session.typed "v a f"
          let selected := lastViewLine (← session.sceneLines)
          session.typed "<Escape> d a f"
          let deleted := lastViewLine (← session.sceneLines)
          let some fnAt := offsetOf rustObjectsText "fn one" | return false
          let some closing := offsetOf rustObjectsText "}\n}\n" | return false
          let some letAt := offsetOf rustObjectsText "let x" | return false
          -- `d` over a charwise span from a line's indent to the end of a
          -- later line takes the lines whole, Vim's exception for `d`.
          let without := "struct S;\n\nimpl S {\n}\n"
          return (before.splitOn s!"selections {letAt}..{letAt},").length == 2 &&
              (selected.splitOn s!"selections {fnAt}..{closing},").length == 2 &&
              (deleted.splitOn s!"{without.quote}, scroll").length == 2 },
    { name :=
        "in a Rust buffer v i f from a method's fn line, in the function and outside its body, selects inside the body's braces, its lines whole, through the host's loop and the library's syntax tree"
      run :=
        withVimHost context [("init.lean", rustObjectsConfig)] fun session => do
          session.ask [.reload]
          session.ask [.run "rust-buffer"]
          session.typed "k v i f"
          let selected := lastViewLine (← session.sceneLines)
          let some letAt := offsetOf rustObjectsText "        let x" | return false
          let some closing := offsetOf rustObjectsText "\n    }\n}" | return false
          unless (selected.splitOn s!"selections {letAt}..{closing},").length == 2 do
            throw (IO.userError selected)
          return true }]

end ConfigTest
