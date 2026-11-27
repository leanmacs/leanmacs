import ContractTest.Check
import ContractTest.Support.Displays
import ContractTest.Support.Syntax
import Editor.Clipboard
import Editor.Command
import Editor.Command.Real
import Editor.Display
import Editor.Display.Real
import Editor.Display.Recorder
import Editor.Face
import Editor.Ffi.Display
import Editor.Ffi.Document
import Editor.Ffi.Events
import Editor.Ffi.Snapshot
import Editor.Ffi.Syntax
import Editor.Ffi.Window
import Editor.Highlight
import Editor.Indent
import Editor.Language
import Editor.Menu
import Editor.Mode
import Editor.Program
import Editor.RealHost
import Editor.Scene
import Editor.SyntaxTree
import Editor.SyntaxTree.Contract
import Editor.SyntaxTree.Real
import Editor.Test.Linked.Syntax
import Editor.Text
import Editor.Text.Real
import Editor.Vocabulary
import Editor.Watch

/-!
# Contract tests: `Editor/SyntaxTree/Real.lean`

The tests of `Editor/SyntaxTree/Real.lean`: `syntaxFixtureChecks` and
`syntaxTreeChecks`, what only the real syntax tree binding shows. The root
module `ContractTest` runs them; its module doc says what each shows.
-/

namespace ContractTest

open Editor
open Editor.Test.Linked (settlingAttach drainedParsed)

/-- Whether the editor queue holds exactly one event, the library's report
of a parse delivered, which is pulled: what an edit of a highlighted text
leaves once its tree is delivered. It never parks a pull on an empty
queue. -/
def pulledParsed : IO Bool := do
  unless (← Ffi.queued .editor) == 1 do
    return false
  let some event ← Ffi.takeQueued .editor | return false
  return event.kind == .parsed && event.source.kind == .library

/-- The mark of `onRealSyntaxTree`: it runs a real background service (`Editor/RealHost.lean`). -/
def onRealSyntaxTree.realHost : Editor.RealHost :=
  .service

/-- Runs `check` against the real syntax tree binding over documents of
`texts`, handed the documents, which it may edit, the table of snapshots the
binding reads, which it may add to, the snapshots' ids and the binding's
handler; whether it answered `true`. -/
def onRealSyntaxTree (texts : Array String)
    (check : Array Ffi.Document → Snapshots → Array SnapshotId → SyntaxTreeHandler → IO Bool) :
    IO Bool := do
  let (documents, table, ids, handler) ← syntaxTreeOver texts
  let held ← check documents table ids handler
  for document in documents do
    discard document.read
  return held

/-- The captures `query` answers of the whole of `text`, as the texts of
their nodes. -/
def capturedTexts (text : String) (captures : Array SyntaxTree.Capture) : Array String :=
  captures.map fun capture => String.fromUTF8! (text.toUTF8.extract capture.start capture.stop)

/-- The capture names of the query of `kind` the library ships for
`grammar`; none when it ships none or the query does not compile. -/
def shippedNames (grammar : String) (kind : QueryKind) : IO (Option (Array String)) := do
  let table ← Snapshots.new
  let real ← RealSyntaxTree.new table.reader
  let program : SyntaxTreeM (Array String) := do
    let query ← SyntaxTree.compile grammar (← SyntaxTree.shippedQuery grammar kind)
    SyntaxTree.captureNames query
  return (← program.runWith real.handle).toOption

/-- What the indent primitive answers of each row of `text`, whose major
mode is the shipped Rust one, over the real syntax tree binding: the text,
the levels, and the texts the run left. Each question waits for its
snapshot's tree (`settling`). -/
def rustIndentLevels (table : Snapshots) (texts : RealTexts) (text : TextId) :
    IO (Option (Array (Option Nat))) := do
  let real ← RealSyntaxTree.new table.reader
  let levels : EditorM (Except SyntaxTreeError (Array (Option Nat))) := do
    text.indentLevels 0 ((← text.rowCount) - 1)
  let (.ok (.ok answered), _) ←
    levels.runReal texts (← recorderOf table).handle (syntaxTree :=
        settling table real.handle) | return none
  return some answered

/-- The opening level of a Rust text, written with a bar where the line
opens (`fixture`), whose major mode is the shipped Rust one, over the real
syntax tree binding, with what follows the bar on its row moved to the new
row when `rest`: `none` when the run was refused. The question waits for
its snapshot's tree (`settling`). -/
def rustOpeningLevel (fixture : String) (rest : Bool) :
    IO (Option (Except SyntaxTreeError (Option Nat))) := do
  let offset := ((fixture.splitOn "|").headD "").utf8ByteSize
  let source := fixture.replace "|" ""
  let table ← Snapshots.new
  let real ← RealSyntaxTree.new table.reader
  let asked : EditorM (Except SyntaxTreeError (Option Nat)) := do
    let text ← createText source
    Highlight.enter "rust" text { grammar := "rust" }
    text.openingLevel offset rest
  let (.ok answered, _) ←
    asked.runReal (.over table) (← recorderOf table).handle (syntaxTree :=
        settling table real.handle) | return none
  return some answered

/-- The rows of the opening rule's table over the real Rust grammar: a text
with a bar where a line opens, whether what follows the bar moves to the
new row (`RET`) or the new row is empty (`o`, `O`), and the level. -/
def rustOpeningRows : List (String × Bool × Option Nat) :=
  [("fn main() {|\n    let x = 1;\n}\n", true, some 1), ("fn main() {|}\n", true, some 0),
    ("fn main() {|", true, some 1), ("struct S {|", true, some 1),
    ("impl A {\n    fn f(&self) {|", true, some 2),
    ("fn main() {\n    if a {\n        if b {|", true, some 3),
    ("fn main() {\n    match x {|\n}\n", true, some 2),
    ("fn main() {\n    if a {|\n    let y = 2;\n}\n", true, some 2),
    ("fn main() {\n    foo(|\n}\n", true, some 2),
    ("fn main() {\n    let v = vec![|\n}\n", true, some 2),
    ("fn main() {\n    let x = ;\n    if a {|\n    }\n}\n", true, some 2),
    ("fn main() {\n    let x = 1;\n}|\n", false, some 0),
    ("fn main() {\n    let x = 1;\n|}\n", false, some 1),
    ("fn main() {\n    let x = 1;\n|}\n", true, some 0),
    ("fn main() {\n|    let x = 1;\n}\n", false, some 1),
    ("impl A {\n    fn f() {\n        x();|\n    }\n}\n", false, some 2),
    ("fn main() {\n    let s = \"ab|c\";\n}\n", true, none)]

/-- The levels the indent rule must give `source`, a rustfmt-formatted Rust
text indented four spaces a level, for each of its rows: `none` for the
rows in `kept`, kept as they are, `some` of the leading spaces divided by
four for every other row with content, and nothing asked of a blank row. -/
def rustIndentHolds (source : String) (kept : List String) (levels : Array (Option Nat)) : Bool :=
  let lines := (source.splitOn "\n").toArray
  lines.size == levels.size &&
    (lines.zip levels).all fun (line, level) =>
      if kept.contains line then level == none
      else
        if line.trimAscii.isEmpty then true
        else level == some ((line.toList.takeWhile (· == ' ')).length / 4)

/-- Rust texts with a bracket the tree did not close, each indented as its
levels must be: a call's `(` and an array's `[` whose partner is missing,
mid-function, followed by another function, whose rows after the bracket's
node keep their levels; and brackets left open at the text's end, which
the error that holds them counts on every row it reaches. -/
def rustUnclosedTexts : List String :=
  ["fn a() {\n    foo(1;\n}\n\nfn b() {\n    x\n}\n",
    "fn a() {\n    let v = [1, 2;\n}\n\nfn b() {\n    x\n}\n", "fn main() {\n    let x = 1;\n",
    "impl A {\n    fn f(&self) {\n        x();\n"]

/-- The indent levels of `source`, whose major mode is the shipped Rust one,
over the real syntax tree binding: `none` when the run was refused. The
question waits for its snapshot's tree (`settling`). -/
def rustSourceLevels (source : String) : IO (Option (Array (Option Nat))) := do
  let table ← Snapshots.new
  let real ← RealSyntaxTree.new table.reader
  let entered : EditorM TextId := do
    let text ← createText source
    Highlight.enter "rust" text { grammar := "rust" }
    return text
  let (.ok text, texts) ←
    entered.runReal (.over table) (← recorderOf table).handle (syntaxTree :=
        settling table real.handle) | return none
  rustIndentLevels table texts text

/-- What only the real syntax tree binding shows over the fixtures in
`fixtures` (`tests/syntax`): the indent levels of a Rust fixture, before
and after an edit, and the names the shipped Rust indents query captures.
The tree's text objects over the binding are evil's
(`EvilTest.Linked.treeObjectFixtureChecks`, `packages/evil/EvilTest/Linked/Evil/TreeObjects.lean`). -/
def syntaxFixtureChecks (fixtures : System.FilePath) : List Check :=
  [{  name := "the shipped Rust indents query names only what the indent rule reads"
      run := do
        let some names ← shippedNames "rust" .indents | return false
        return !names.isEmpty && names.all Indent.names.contains },
    { name :=
        "the indent levels of the Rust fixture are its own indentation, and the rows inside its multi-line string and block comment keep theirs, before and after an edit that wraps a statement in a new block"
      run := do
        let source ← IO.FS.readFile (fixtures / "rust" / "indent.rs")
        let kept := ["not indented by the rule\";", "       comment */"]
        let table ← Snapshots.new
        let real ← RealSyntaxTree.new table.reader
        let entered : EditorM TextId := do
          let text ← createText source
          Highlight.enter "rust" text { grammar := "rust" }
          return text
        let (.ok text, texts) ←
          entered.runReal (.over table) (← recorderOf table).handle (syntaxTree :=
              settling table real.handle) | return false
        let some before ← rustIndentLevels table texts text | return false
        -- A statement wrapped in a new `if` block, formatted.
        let statement := "                let y = x + 1;\n"
        let wrapped :=
          "                if y > 0 {\n                    let y = x + 1;\n                }\n"
        let some offset := (source.splitOn statement).head?.map (·.utf8ByteSize) | return false
        let edit : EditorM Unit := do
          text.delete offset (offset + statement.utf8ByteSize)
          text.insert offset wrapped
        let (.ok (), texts) ← edit.runReal texts (← recorderOf table).handle | return false
        let edited := source.replace statement wrapped
        let some after ← rustIndentLevels table texts text | return false
        -- The documents are read, so they live to here.
        let read : EditorM String := text.read
        let (.ok now, _) ← read.runReal texts (← recorderOf table).handle | return false
        return now == edited && rustIndentHolds source kept before &&
            rustIndentHolds edited kept after },
    { name :=
        "the opening level of Rust texts at an unclosed bracket counts every bracket the tree did not close, widened to the incomplete node that holds them: closed and unclosed at the text's end, three deep, a match, an if, a call and a vec! opened mid-function, a balanced error elsewhere, o and O on a closing row and in a body, and nothing inside a string"
      run := do
        let mut wrong := #[]
        for (fixture, rest, level) in rustOpeningRows do
          let answered ← rustOpeningLevel fixture rest
          let said :=
            match answered with
            | some (.ok got) => if got == level then none else some (repr got)
            | some (.error refusal) => some (repr refusal)
            | none => some "nothing"
          if let some said := said then
            wrong := wrong.push s!"{repr fixture} (rest {rest}) answered {said}"
        unless wrong.isEmpty do
          throw (IO.userError ("; ".intercalate wrong.toList))
        return true },
    { name :=
        "the indent levels of Rust texts with a bracket the tree did not close are their own indentation: a call's ( and an array's [ whose partner is missing mid-function count on no row after their node, so the function's } and the next function keep their levels, and brackets open at the text's end count on the rows their error holds"
      run := do
        let mut wrong := #[]
        for source in rustUnclosedTexts do
          match ← rustSourceLevels source with
          | some levels =>
            unless rustIndentHolds source [] levels do
              wrong := wrong.push s!"{repr source} answered {repr levels}"
          | none =>
            wrong := wrong.push s!"{repr source} was refused"
        unless wrong.isEmpty do
          throw (IO.userError ("; ".intercalate wrong.toList))
        return true }]

/-- What only the real syntax tree binding shows: the library's Rust
grammar, a query of one grammar asked of a text parsed with another, and a
text edited through its document reparsed. -/
def syntaxTreeChecks : List Check :=
  [{  name := "the library's syntax service has a Rust grammar beside JSON"
      run := do
        let grammars ←
          SyntaxTree.grammars.runWith fun request => do
              let (_, _, _, handler) ← syntaxTreeOver #[]
              handler request
        return grammars.toOption.any fun names => names.contains "rust" && names.contains "json" },
    { name := "a Rust function's name is captured through the binding, by its field"
      run :=
        onRealSyntaxTree #["fn one() {}\nstruct S;\nfn two(x: u8) {}\n"] fun _ _ ids handler => do
          let program : SyntaxTreeM (Array SyntaxTree.Capture) := do
            SyntaxTree.attach (SyntaxTreeContract.nth ids 0) "rust"
            let query ← SyntaxTree.compile "rust" "(function_item name: (identifier) @name)"
            SyntaxTree.captures (SyntaxTreeContract.nth ids 0) query 0 39
          let text := "fn one() {}\nstruct S;\nfn two(x: u8) {}\n"
          return match ← program.runWith handler with
            | .ok captures => capturedTexts text captures == #["one", "two"]
            | .error _ => false },
    { name := "a query of JSON asked of a text parsed as Rust is refused as of the wrong grammar"
      run :=
        onRealSyntaxTree #["fn one() {}"] fun _ _ ids handler => do
          let program : SyntaxTreeM Bool := do
            SyntaxTree.attach (SyntaxTreeContract.nth ids 0) "rust"
            let query ← SyntaxTree.compile "json" "(number) @n"
            SyntaxTreeContract.refusedWith .wrongGrammar
                (SyntaxTree.captures (SyntaxTreeContract.nth ids 0) query 0 3)
          return (← program.runWith handler) matches .ok true },
    { name :=
        "a text edited through its document is reparsed: its new function's name is captured once the tree of the edit is delivered"
      run :=
        onRealSyntaxTree #["fn one() {}\n"] fun documents table ids handler => do
          let some document := documents[0]? | return false
          let attached ← (SyntaxTree.attach (SyntaxTreeContract.nth ids 0) "rust").runWith handler
          unless (← document.replace 0 0 "fn zero() {}\n") == .done do
            return false
          -- The snapshot of the edited text enters the table, as the
          -- editor's would after the edit.
          let edited ← table.add (← document.snapshot)
          let program : SyntaxTreeM (Array SyntaxTree.Capture) := do
            let query ← SyntaxTree.compile "rust" "(function_item name: (identifier) @name)"
            SyntaxTree.captures edited query 0 25
          let text := "fn zero() {}\nfn one() {}\n"
          return attached matches .ok () &&
              match ← program.runWith handler with
              | .ok captures => capturedTexts text captures == #["zero", "one"]
              | .error _ => false },
    { name :=
        "an injection and a keep with a query of another grammar than the text's, and a language whose injections query is of another grammar than its highlights query, are refused as of the wrong grammar"
      run :=
        onRealSyntaxTree #["fn one() {}"] fun _ _ ids handler => do
          let snapshot := SyntaxTreeContract.nth ids 0
          let program : SyntaxTreeM Bool := do
            SyntaxTree.attach snapshot "rust"
            let json ← SyntaxTree.compile "json" "(number) @n"
            let rust ← SyntaxTree.compile "rust" "(identifier) @id"
            return (←
                  SyntaxTreeContract.refusedWith .wrongGrammar (SyntaxTree.inject snapshot json)) &&
                (←
                  SyntaxTreeContract.refusedWith .wrongGrammar
                      (SyntaxTree.keep snapshot .indents json)) &&
                (←
                  SyntaxTreeContract.refusedWith .wrongGrammar
                      (SyntaxTree.injectLanguage snapshot "rust" rust #[none] (some json)))
          return (← program.runWith handler) matches .ok true },
    { name :=
        "a highlight with a query of another grammar than its text's is refused as of the wrong grammar"
      run :=
        onRealSyntaxTree #["fn one() {}"] fun _ _ ids handler => do
          let program : SyntaxTreeM Bool := do
            SyntaxTree.attach (SyntaxTreeContract.nth ids 0) "rust"
            let query ← SyntaxTree.compile "json" "(number) @n"
            SyntaxTreeContract.refusedWith .wrongGrammar
                (SyntaxTree.highlight (SyntaxTreeContract.nth ids 0) query #[none])
          return (← program.runWith handler) matches .ok true },
    { name :=
        "a Rust text highlighted by the shipped default and edited is drawn by the real display with its keywords in the keyword face's colour, once the edit's tree is delivered and reported on the editor queue"
      run := do
        let table ← Snapshots.new
        let real ← RealSyntaxTree.new table.reader
        let syntaxTree := settlingAttach table real.handle
        let red := Color.rgb 0xcc 0 0
        let display ← Ffi.Display.newCells 8 16
        let shown ←
          RealDisplay.over display table.reader
              #[{ name := ⟨"syntax.keyword"⟩, face := { foreground := some red } }]
        let highlighted : EditorM TextId := do
          let text ← createText "fn one() {}\n"
          Highlight.enter "rust" text { grammar := "rust" }
          return text
        let (.ok text, texts) ←
          highlighted.runReal (.over table) shown.handle (syntaxTree := syntaxTree) | return false
        let edited : EditorM (SnapshotId × MarkerId) := do
          text.insert 0 "fn zero() {}\n"
          return (← text.snapshot, ← text.mark (.anchor { offset := 0, bias := .before }))
        let (.ok (snapshot, scroll), texts) ←
          edited.runReal texts shown.handle (syntaxTree := syntaxTree) | return false
        let some found ← table.find? snapshot | return false
        unless ← Ffi.syntaxSettle found Ffi.treeGuard do
          return false
        let reported ← pulledParsed
        let scene : Scene :=
          { size := { width := 160, height := 64 }
            views :=
              #[{ id := ⟨0⟩, rect := { x := 0, y := 0, width := 160, height := 64 }, snapshot
                  scroll, selections := #[], cursor := { shape := .block, face := ⟨"cursor"⟩ }
                  decorations := #[], status := #[] }]
            focused := none, echo := "", pending := "", preedit := none }
        let publish : EditorM Unit := Display.publish scene
        let (published, _) ← publish.runReal texts shown.handle
        let frame ← display.frameText
        -- Each row starts with `fn`: its first run, two bytes, in red.
        return reported && published.isOk && (frame.splitOn "runs 0..2:cc0000ff/").length == 3 },
    { name :=
        "a TOML text entered with the toml language's tree is drawn by the real display with its table header's key and its key in the type face's colour, its string in the string face's colour and the header's brackets in the punctuation face's colour"
      run := do
        let table ← Snapshots.new
        let real ← RealSyntaxTree.new table.reader
        let syntaxTree := settlingAttach table real.handle
        let red := Color.rgb 0xcc 0 0
        let green := Color.rgb 0 0xcc 0
        let blue := Color.rgb 0 0 0xcc
        let display ← Ffi.Display.newCells 8 16
        let shown ←
          RealDisplay.over display table.reader
              #[{ name := ⟨"syntax.type"⟩, face := { foreground := some red } },
                { name := ⟨"syntax.string"⟩, face := { foreground := some green } },
                { name := ⟨"syntax.punctuation"⟩, face := { foreground := some blue } }]
        let entered : EditorM (SnapshotId × MarkerId) := do
          let text ← createText "[package]\nname = \"x\"\n"
          Highlight.enter "toml" text Language.toml.syntaxTree
          return (← text.snapshot, ← text.mark (.anchor { offset := 0, bias := .before }))
        let (.ok (snapshot, scroll), texts) ←
          entered.runReal (.over table) shown.handle (syntaxTree := syntaxTree) | return false
        let some found ← table.find? snapshot | return false
        unless ← Ffi.syntaxSettle found Ffi.treeGuard do
          return false
        discard drainedParsed
        let scene : Scene :=
          { size := { width := 160, height := 64 }
            views :=
              #[{ id := ⟨0⟩, rect := { x := 0, y := 0, width := 160, height := 64 }, snapshot
                  scroll, selections := #[], cursor := { shape := .block, face := ⟨"cursor"⟩ }
                  decorations := #[], status := #[] }]
            focused := none, echo := "", pending := "", preedit := none }
        let publish : EditorM Unit := Display.publish scene
        let (published, _) ← publish.runReal texts shown.handle
        let frame ← display.frameText
        -- `[package]`: the brackets blue, the key red; `name = "x"`: the key
        -- red, ` = ` in no face of these, the string green.
        let header := "runs 0..1:0000ccff/ffffffff 1..8:cc0000ff/ffffffff 8..9:0000ccff/ffffffff\n"
        let pair := "runs 0..4:cc0000ff/ffffffff 4..7:000000ff/ffffffff 7..10:00cc00ff/ffffffff\n"
        return published.isOk && (frame.splitOn header).length == 2 &&
            (frame.splitOn pair).length == 2 },
    { name :=
        "a Lean text entered with the lean language's tree is drawn by the real display with its keyword in the keyword face's colour, its string in the string face's colour and its comment in the comment face's colour"
      run := do
        let table ← Snapshots.new
        let real ← RealSyntaxTree.new table.reader
        let syntaxTree := settlingAttach table real.handle
        let red := Color.rgb 0xcc 0 0
        let green := Color.rgb 0 0xcc 0
        let blue := Color.rgb 0 0 0xcc
        let display ← Ffi.Display.newCells 8 16
        let shown ←
          RealDisplay.over display table.reader
              #[{ name := ⟨"syntax.keyword"⟩, face := { foreground := some red } },
                { name := ⟨"syntax.string"⟩, face := { foreground := some green } },
                { name := ⟨"syntax.comment"⟩, face := { foreground := some blue } }]
        let entered : EditorM (SnapshotId × MarkerId) := do
          let text ← createText "def x := \"a\"\n-- c\n"
          Highlight.enter "lean" text Language.lean.syntaxTree
          return (← text.snapshot, ← text.mark (.anchor { offset := 0, bias := .before }))
        let (.ok (snapshot, scroll), texts) ←
          entered.runReal (.over table) shown.handle (syntaxTree := syntaxTree) | return false
        let some found ← table.find? snapshot | return false
        unless ← Ffi.syntaxSettle found Ffi.treeGuard do
          return false
        discard drainedParsed
        let scene : Scene :=
          { size := { width := 160, height := 64 }
            views :=
              #[{ id := ⟨0⟩, rect := { x := 0, y := 0, width := 160, height := 64 }, snapshot
                  scroll, selections := #[], cursor := { shape := .block, face := ⟨"cursor"⟩ }
                  decorations := #[], status := #[] }]
            focused := none, echo := "", pending := "", preedit := none }
        let publish : EditorM Unit := Display.publish scene
        let (published, _) ← publish.runReal texts shown.handle
        let frame ← display.frameText
        -- `def x := "a"`: `def` red, ` x := ` in no face of these, the
        -- string green; `-- c`: the comment blue.
        let definition :=
          "runs 0..3:cc0000ff/ffffffff 3..9:000000ff/ffffffff 9..12:00cc00ff/ffffffff\n"
        let comment := "runs 0..4:0000ccff/ffffffff\n"
        return published.isOk && (frame.splitOn definition).length == 2 &&
            (frame.splitOn comment).length == 2 },
    { name :=
        "a Lean text entered with the lean language's tree is drawn by the real display with a namespace's name in the module face's colour, not hidden by the identifier's variable capture"
      run := do
        let table ← Snapshots.new
        let real ← RealSyntaxTree.new table.reader
        let syntaxTree := settlingAttach table real.handle
        let red := Color.rgb 0xcc 0 0
        let yellow := Color.rgb 0xcc 0xcc 0
        let display ← Ffi.Display.newCells 8 16
        let shown ←
          RealDisplay.over display table.reader
              #[{ name := ⟨"syntax.keyword"⟩, face := { foreground := some red } },
                { name := ⟨"syntax.module"⟩, face := { foreground := some yellow } }]
        let entered : EditorM (SnapshotId × MarkerId) := do
          let text ← createText "namespace A.B\n"
          Highlight.enter "lean" text Language.lean.syntaxTree
          return (← text.snapshot, ← text.mark (.anchor { offset := 0, bias := .before }))
        let (.ok (snapshot, scroll), texts) ←
          entered.runReal (.over table) shown.handle (syntaxTree := syntaxTree) | return false
        let some found ← table.find? snapshot | return false
        unless ← Ffi.syntaxSettle found Ffi.treeGuard do
          return false
        discard drainedParsed
        let scene : Scene :=
          { size := { width := 160, height := 64 }
            views :=
              #[{ id := ⟨0⟩, rect := { x := 0, y := 0, width := 160, height := 64 }, snapshot
                  scroll, selections := #[], cursor := { shape := .block, face := ⟨"cursor"⟩ }
                  decorations := #[], status := #[] }]
            focused := none, echo := "", pending := "", preedit := none }
        let publish : EditorM Unit := Display.publish scene
        let (published, _) ← publish.runReal texts shown.handle
        let frame ← display.frameText
        -- `namespace A.B`: `namespace` red, the space in no face of these,
        -- the name `A.B` yellow.
        let line := "runs 0..9:cc0000ff/ffffffff 9..10:000000ff/ffffffff 10..13:cccc00ff/ffffffff\n"
        return published.isOk && (frame.splitOn line).length == 2 },
    { name :=
        "a Markdown text with a fenced Rust block, entered with the shipped default, is drawn by the real display with the fence's `fn` in the keyword face's colour"
      run := do
        let table ← Snapshots.new
        let real ← RealSyntaxTree.new table.reader
        let syntaxTree := settlingAttach table real.handle
        let red := Color.rgb 0xcc 0 0
        let display ← Ffi.Display.newCells 8 16
        let shown ←
          RealDisplay.over display table.reader
              #[{ name := ⟨"syntax.keyword"⟩, face := { foreground := some red } }]
        let entered : EditorM (SnapshotId × MarkerId) := do
          let text ← createText "# Title\n\n```rust\nfn one() {}\n```\n"
          Highlight.enter "markdown" text { grammar := "markdown" }
          return (← text.snapshot, ← text.mark (.anchor { offset := 0, bias := .before }))
        let (.ok (snapshot, scroll), texts) ←
          entered.runReal (.over table) shown.handle (syntaxTree := syntaxTree) | return false
        let some found ← table.find? snapshot | return false
        -- The settle waits for the layers the injections find, which the
        -- library delivers at the same revision.
        unless ← Ffi.syntaxSettle found Ffi.treeGuard do
          return false
        let reported ← drainedParsed
        let scene : Scene :=
          { size := { width := 160, height := 96 }
            views :=
              #[{ id := ⟨0⟩, rect := { x := 0, y := 0, width := 160, height := 96 }, snapshot
                  scroll, selections := #[], cursor := { shape := .block, face := ⟨"cursor"⟩ }
                  decorations := #[], status := #[] }]
            focused := none, echo := "", pending := "", preedit := none }
        let publish : EditorM Unit := Display.publish scene
        let (published, _) ← publish.runReal texts shown.handle
        let frame ← display.frameText
        -- One row starts with a keyword: the fence's `fn`, in red.
        return reported > 0 && published.isOk &&
            (frame.splitOn "runs 0..2:cc0000ff/").length == 2 },
    { name :=
        "a Markdown text with emphasis and inline code, entered with the inline grammar's captures mapped to faces, is drawn by the real display with the emphasis and the code span in their faces' colours"
      run := do
        let table ← Snapshots.new
        let real ← RealSyntaxTree.new table.reader
        let syntaxTree := settlingAttach table real.handle
        let green := Color.rgb 0 0xcc 0
        let blue := Color.rgb 0 0 0xcc
        let display ← Ffi.Display.newCells 8 16
        let shown ←
          RealDisplay.over display table.reader
              #[{ name := ⟨"test.emphasis"⟩, face := { foreground := some green } },
                { name := ⟨"test.literal"⟩, face := { foreground := some blue } }]
        -- The delimiters draw nothing, so each span is one run. The text has
        -- no fenced block: `text.literal` here can only be the inline
        -- layer's.
        let captures :=
          [("text.emphasis", some ⟨"test.emphasis"⟩), ("text.literal", some ⟨"test.literal"⟩),
            ("punctuation.delimiter", none)]
        let entered : EditorM (SnapshotId × MarkerId) := do
          let text ← createText "Some *emphasis* and `code`.\n"
          Highlight.enter "markdown" text { grammar := "markdown", captures }
          return (← text.snapshot, ← text.mark (.anchor { offset := 0, bias := .before }))
        let (.ok (snapshot, scroll), texts) ←
          entered.runReal (.over table) shown.handle (syntaxTree := syntaxTree) | return false
        let some found ← table.find? snapshot | return false
        unless ← Ffi.syntaxSettle found Ffi.treeGuard do
          return false
        discard drainedParsed
        let scene : Scene :=
          { size := { width := 320, height := 32 }
            views :=
              #[{ id := ⟨0⟩, rect := { x := 0, y := 0, width := 320, height := 32 }, snapshot
                  scroll, selections := #[], cursor := { shape := .block, face := ⟨"cursor"⟩ }
                  decorations := #[], status := #[] }]
            focused := none, echo := "", pending := "", preedit := none }
        let publish : EditorM Unit := Display.publish scene
        let (published, _) ← publish.runReal texts shown.handle
        let frame ← display.frameText
        -- `*emphasis*` is bytes 5 to 15 of its row, and `` `code` `` 20 to 26.
        return published.isOk && (frame.splitOn "5..15:00cc00ff").length == 2 &&
            (frame.splitOn "20..26:0000ccff").length == 2 },
    { name :=
        "a Markdown text entered with the shipped default is drawn with its heading, emphasis, code span and link in the text faces"
      run := do
        let table ← Snapshots.new
        let real ← RealSyntaxTree.new table.reader
        let syntaxTree := settlingAttach table real.handle
        let colours :=
          [("text.heading.1", Color.rgb 0xcc 0 0), ("text.emphasis", Color.rgb 0 0xcc 0),
            ("text.code-span", Color.rgb 0 0 0xcc), ("text.link", Color.rgb 0xcc 0xcc 0)]
        let display ← Ffi.Display.newCells 8 16
        -- Only the text faces are defined: `syntax.punctuation`, which the
        -- delimiters are drawn in, sets nothing, so each span is one run.
        let shown ←
          RealDisplay.over display table.reader
              (colours.toArray.map fun (name, colour) =>
                { name := ⟨name⟩, face := { foreground := some colour } })
        let heading := "# Title"
        let paragraph := "Some *em* and `code` and [link](u)."
        let entered : EditorM (SnapshotId × MarkerId) := do
          let text ← createText s!"{heading}\n\n{paragraph}\n"
          Highlight.enter "markdown" text { grammar := "markdown" }
          return (← text.snapshot, ← text.mark (.anchor { offset := 0, bias := .before }))
        let (.ok (snapshot, scroll), texts) ←
          entered.runReal (.over table) shown.handle (syntaxTree := syntaxTree) | return false
        let some found ← table.find? snapshot | return false
        unless ← Ffi.syntaxSettle found Ffi.treeGuard do
          return false
        discard drainedParsed
        let scene : Scene :=
          { size := { width := 640, height := 64 }
            views :=
              #[{ id := ⟨0⟩, rect := { x := 0, y := 0, width := 640, height := 64 }, snapshot
                  scroll, selections := #[], cursor := { shape := .block, face := ⟨"cursor"⟩ }
                  decorations := #[], status := #[] }]
            focused := none, echo := "", pending := "", preedit := none }
        let publish : EditorM Unit := Display.publish scene
        let (published, _) ← publish.runReal texts shown.handle
        let frame ← display.frameText
        -- The run of `needle` in `row`, from its byte offsets in the row,
        -- in the colour of `face`.
        let run (row needle face : String) : String :=
          let start := (row.splitOn needle).head!.utf8ByteSize
          let colour := ((colours.lookup face).map (·.word)).getD 0
          let hex := String.ofList (Nat.toDigits 16 colour.toNat)
          s!"{start}..{start + needle.utf8ByteSize}:{"".pushn '0' (8 - hex.length)}{hex}"
        let runs :=
          [run heading "Title" "text.heading.1", run paragraph "*em*" "text.emphasis",
            run paragraph "`code`" "text.code-span", run paragraph "link" "text.link"]
        return published.isOk && runs.all fun expected => (frame.splitOn expected).length == 2 }]

end ContractTest
