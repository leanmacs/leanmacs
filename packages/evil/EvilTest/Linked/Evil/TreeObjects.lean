import Editor.File.Model
import Editor.Test.Linked.Host
import Editor.Test.Linked.Keys
import Editor.Test.Linked.Lines
import Editor.Test.Linked.Shipped
import Editor.Test.Linked.Syntax
import Editor.Vocabulary
import Evil.TreeObjects
import EvilTest.Check
import EvilTest.Linked.Support.Vim

/-!
# Linked tests: `Evil/TreeObjects.lean`

The tests of `Evil/TreeObjects.lean`: `treeObjectChecks`, through a host
of the Vim scheme that ships over the real syntax tree binding, and
`treeObjectFixtureChecks`, the objects' spans over the real binding with no
host, on the syntax fixtures. The root module `EvilTest.Linked` runs them; its
module doc says what each shows.
-/

namespace EvilTest.Linked

open Editor
open Editor.Test.Linked

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
scheme that ships (`withRealVimHost`), with the real elaborator, the real text
binding and the library's syntax service: what keys select and delete in a
Rust buffer. Which node an object is, is `Evil/TreeObjects.lean`'s,
pinned by `EvilTest.treeObjectRuleChecks` and `EvilTest.evilObjectChecks`
and, over the library, by `ContractTest`. -/
def treeObjectChecks (context : HostContext) : List Check :=
  [{  name :=
        "in a Rust buffer v a f selects the enclosing function, from its fn through its closing brace, through the host's loop and the library's syntax tree; and <Escape> d a f then deletes it, its lines whole"
      run :=
        -- Seen to bite once by hand: with `a-function` taken out of
        -- `Evil.objects`, `v a f` leaves the cursor's one cell selected.
        withRealVimHost context [("init.lean", rustObjectsConfig)] fun session => do
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
        withRealVimHost context [("init.lean", rustObjectsConfig)] fun session => do
          session.ask [.reload]
          session.ask [.run "rust-buffer"]
          session.typed "k v i f"
          let selected := lastViewLine (← session.sceneLines)
          let some letAt := offsetOf rustObjectsText "        let x" | return false
          let some closing := offsetOf rustObjectsText "\n    }\n}" | return false
          unless (selected.splitOn s!"selections {letAt}..{closing},").length == 2 do
            throw (IO.userError selected)
          return true }]

/-- A row of the tree's text objects over the Rust fixture: where the
cursor is, as the text it is at the start of (its first occurrence), the
object, the count, where the anchor of a visual selection is, as a text
whose first occurrence it is at the start of, or the end of when `atEnd`,
and the text the object covers and how, or none for no object. -/
structure ObjectRow where
  /-- The text the cursor is at the start of. -/
  needle : String
  /-- The object. -/
  object : Vocabulary.TextObject
  /-- The count, if one was typed. -/
  count : Option Nat := none
  /-- The text the anchor is at, in a visual state. -/
  anchor : Option (String × Bool) := none
  /-- What it covers: its text and its reach; none for no object. -/
  covers : Option (String × Vocabulary.Reach)

/-- The rows of the tree's text objects over `tests/syntax/rust/objects.rs`,
written by hand: all six objects; a count of 2, the method round a
closure; a visual selection of the closure widened to the method; the
inside of a unit struct, which is none; an argument first, last, alone and
on lines of its own; the inside of a closure whose body is an expression;
and the inside of a function, a struct, an impl and a closure from a cursor
in the node but outside the inside, on its `fn`, `struct`, `impl` or
parameters. -/
def objectRows : List ObjectRow :=
  [{  needle := "a + b", object := Evil.aFunction
      covers := some ("fn free(a: u8, b: u8) -> u8 {\n    a + b\n}", .exclusive) },
    { needle := "a + b", object := Evil.innerFunction, covers := some ("    a + b\n", .exclusive) },
    { needle := "v + extra", object := Evil.aFunction,
      covers := some ("|v| v + extra", .exclusive) },
    { needle := "v + extra", object := Evil.innerFunction,
      covers := some ("v + extra", .exclusive) },
    { needle := "v + extra", object := Evil.aFunction, count := some 2
      covers :=
        some
          ("fn sum(&self, extra: u8) -> u8 {\n        let add = |v| v + extra;\n        add(self.x) + call(\n            self.y,\n            extra,\n        )\n    }",
            .exclusive) },
    { needle := "|v|", object := Evil.aFunction, anchor := some ("v + extra", true)
      covers :=
        some
          ("fn sum(&self, extra: u8) -> u8 {\n        let add = |v| v + extra;\n        add(self.x) + call(\n            self.y,\n            extra,\n        )\n    }",
            .exclusive) },
    { needle := "x: u8", object := Evil.aClass
      covers := some ("struct Fields {\n    x: u8,\n    y: u8,\n}", .exclusive) },
    { needle := "x: u8", object := Evil.innerClass
      covers := some ("    x: u8,\n    y: u8,\n", .exclusive) },
    { needle := "Unit", object := Evil.aClass, covers := some ("struct Unit;", .exclusive) },
    { needle := "Unit", object := Evil.innerClass, covers := none },
    { needle := "Circle", object := Evil.aClass
      covers := some ("enum Shape {\n    Circle(f64),\n    Square(f64),\n}", .exclusive) },
    { needle := "area(&self) -> f64;", object := Evil.aFunction
      covers := some ("fn area(&self) -> f64;", .exclusive) },
    { needle := "area(&self) -> f64;", object := Evil.innerFunction, covers := none },
    { needle := "area(&self) -> f64;", object := Evil.aClass
      covers := some ("trait Area {\n    fn area(&self) -> f64;\n}", .exclusive) },
    { needle := "a: u8", object := Evil.anArgument, covers := some ("a: u8, ", .exclusive) },
    { needle := "b: u8", object := Evil.anArgument, covers := some (", b: u8", .exclusive) },
    { needle := "b: u8", object := Evil.innerArgument, covers := some ("b: u8", .exclusive) },
    { needle := "self.x", object := Evil.anArgument, covers := some ("self.x", .exclusive) },
    { needle := "self.y", object := Evil.anArgument
      covers := some ("self.y,\n            ", .exclusive) },
    { needle := "one: u8", object := Evil.anArgument, covers := some ("one: u8, ", .exclusive) },
    { needle := "fn free", object := Evil.anArgument, covers := none },
    { needle := "fn free", object := Evil.innerFunction,
      covers := some ("    a + b\n", .exclusive) },
    { needle := "struct Fields", object := Evil.innerClass
      covers := some ("    x: u8,\n    y: u8,\n", .exclusive) },
    { needle := "impl Fields", object := Evil.innerClass
      covers :=
        some
          ("    fn sum(&self, extra: u8) -> u8 {\n        let add = |v| v + extra;\n        add(self.x) + call(\n            self.y,\n            extra,\n        )\n    }\n",
            .exclusive) },
    { needle := "|v|", object := Evil.innerFunction, covers := some ("v + extra", .exclusive) }]

/-- The byte offset of the first occurrence of `needle` in `text`, or of
its end when `atEnd`; none when `text` does not hold it. -/
def offsetOfNeedle (text needle : String) (atEnd : Bool := false) : Option Nat :=
  match text.splitOn needle with
  | before :: _ :: _ => some (before.utf8ByteSize + if atEnd then needle.utf8ByteSize - 1 else 0)
  | _ => none

/-- What is wrong with each of `rows` over the text of `held`, a text of
the Rust fixture `source` parsed with the Rust grammar, each row's covered
text edited by `edited`, through the real syntax tree binding. -/
def objectRowsWrong (held : SyntaxText) (source : String) (edited : String → String)
    (rows : List ObjectRow) : IO (List String) :=
  rows.filterMapM fun row => do
    let some head := offsetOfNeedle source row.needle | return some s!"no {row.needle}"
    let anchor := row.anchor.bind fun (needle, atEnd) => offsetOfNeedle source needle atEnd
    let answer ←
      held.run fun text => do
          let some span ←
            row.object.span text
                { head, count := row.count,
                  anchor } | return (none : Option (String × Vocabulary.Reach))
          let stop ←
            if span.reach == .inclusive then
              text.motion .nextCell span.stop
            else
              pure span.stop
          return some (← text.slice span.start stop, span.reach)
    let expected := row.covers.map fun (covered, reach) => (edited covered, reach)
    return match answer with
      | some covers =>
        if covers == expected then none
        else some s!"{row.object.name} at {repr row.needle}: {repr covers}"
      | none => some s!"{row.object.name} at {repr row.needle}: refused"

/-- What only the real syntax tree binding shows of the tree's text objects
over the fixtures in `syntaxFixtures` (the repository's `tests/syntax`), with
no host, through the linked kit's text over the real bindings
(`Editor.Test.Linked.SyntaxText`): the objects of a Rust fixture, before
and after edits, and the names the shipped Rust text objects query
captures. -/
def treeObjectFixtureChecks (syntaxFixtures : System.FilePath) : List Check :=
  [{  name := "the shipped Rust text objects query names only what the text-object rule reads"
      run := do
        let some names ← shippedCaptureNames "rust" .textObjects | return false
        return !names.isEmpty && names.all Evil.TreeObjects.names.contains },
    { name :=
        "the tree's text objects of the Rust fixture, through the Lean editor API, cover the ranges written by hand, and still do after a function is inserted above and a line added inside a method's body"
      run := do
        let source ← IO.FS.readFile (syntaxFixtures / "rust" / "objects.rs")
        let some held ← SyntaxText.over source "rust" | return false
        let before ← objectRowsWrong held source id objectRows
        let line := "        let add = |v| v + extra;\n"
        let added := line ++ "        let unused = 1;\n"
        let inserted := "fn inserted() {}\n\n"
        let some at_ := offsetOfNeedle source line | return false
        let some () ←
          held.run fun text => do
              text.insert (at_ + line.utf8ByteSize) "        let unused = 1;\n"
              text.insert 0 inserted | return false
        let edited := inserted ++ source.replace line added
        let after ← objectRowsWrong held edited (·.replace line added) objectRows
        let some now ← held.run fun text => text.read | return false
        unless before.isEmpty && after.isEmpty do
          throw (IO.userError ("; ".intercalate (before ++ after)))
        return now == edited }]

end EvilTest.Linked
