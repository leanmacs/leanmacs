import ConfigTest.Check
import ConfigTest.Support.Shipped
import Editor.SyntaxTree
import Editor.Test.Linked.Host
import Editor.Test.Linked.Lines
import Editor.Test.Linked.Syntax

/-!
# Config tests: `Editor/Indent.lean`

The tests of `Editor/Indent.lean` through a host: `indentChecks`, on the
syntax fixtures, with commands of config's that ask the text for its indent
levels (`TextId.reindentEdits`, `TextId.openingLevel`). The root module
`ConfigTest` runs them; its module doc says what each shows. What a
scheme's keys do with those levels is that scheme's package's: evil's `=`,
`RET`, `o` and `O` are pinned by `evilIndentChecks`
(`packages/evil/EvilTest/Linked/Evil/Operators.lean`).
-/

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- The texts the indent checks load besides the mangled Rust fixture, each
with the offset its cursor goes to and the language its buffer is set to,
if any: a Rust function closed and one open at the text's end, a method in
an `impl` open at the text's end, a text with no language, and a JSON one,
whose language has no indents query. -/
def reindentFixtures : List (String × String × Nat × Option String) :=
  let closed := "fn main() {\n    let x = 1;\n}\n"
  let nested := "impl S {\n    fn one(&self) {"
  [("closed", closed, "fn main() {".utf8ByteSize, some "rust"),
    ("eof", "fn main() {", "fn main() {".utf8ByteSize, some "rust"),
    ("nested-eof", nested, nested.utf8ByteSize, some "rust"), ("plain", "    ab", 5, none),
    ("json", "[\n  1\n]", 4, some "json")]

/-- A config whose `setup` registers, for the mangled Rust fixture `mangled`
(as `mangled`, its cursor at 0) and each of `reindentFixtures`, the command
`load-<name>`: it puts the text in the scratch buffer's text, in place of
what it held, and the cursor where the fixture says, and then, for a text
with a language, records the language and makes `code` the buffer's major
mode, so the text is parsed as the language says. And two commands over the
core's indent API: `reindent` replaces the leading whitespace of every row
by the edits `TextId.reindentEdits` answers in the buffer's indent unit, or
says `refused: ` and the refusal; `opening` says the level
`TextId.openingLevel` answers of a line opened at the cursor, what follows
it moved to the new row, as `level <n>`, `level kept` or `refused: ` and
the refusal. -/
def reindentText (mangled : String) : String :=
  let commands :=
    (("mangled", mangled, 0, some "rust") :: reindentFixtures).map
      fun (name, text, cursor, language) =>
      let language :=
        match language with
        | some name => s!"(some {name.quote})"
        | none => "none"
      s!"  command {("load-" ++ name).quote} (load {text.quote} {cursor} {language})"
  "def load (contents : String) (cursor : Nat) (language : Option String) : EditorM Unit := do
  let text : TextId := ⟨0⟩
  text.delete 0 (← text.byteLength)
  text.insert 0 contents
  discard <| (⟨0⟩ : ViewId).select { ranges := #[⟨cursor, cursor⟩], shape := .inclusive }
  if let some language := language then
    discard <| (⟨0⟩ : BufferId).setLanguage (some language)
    discard <| (⟨0⟩ : ViewId).setMajorMode \"code\"

def reindent (call : Call) : EditorM Unit := do
  let text := call.target.buffer.text
  match ← text.reindentEdits 0 ((← text.rowCount) - 1) (← call.target.indentUnit) with
  | .error refusal => message s!\"refused: {refusal.describe}\"
  | .ok edits =>
    let before ← call.target.selection
    call.target.replaceEachCarrying edits before before

def opening (call : Call) : EditorM Unit := do
  let selection ← call.target.selection
  let some range := selection.ranges[selection.primary]? | return
  match ← call.target.buffer.text.openingLevel range.head true with
  | .error refusal => message s!\"refused: {refusal.describe}\"
  | .ok (some level) => message s!\"level {level}\"
  | .ok none => message \"level kept\"

def setup : SetupM Unit := do
  commandWith \"reindent\" reindent
  commandWith \"opening\" opening
" ++
    "\n".intercalate commands ++
    "\n"

/-- Runs `check` against a host of the test scheme (`withTestHost`) over
`reindentText` of the mangled Rust indent fixture, with the config loaded:
handed the fixture's text and the mangled one. -/
def withIndentHost (context : Context) (check : Session → String → String → IO Bool) : IO Bool := do
  let source ← IO.FS.readFile (context.syntaxFixtures / "rust" / "indent.rs")
  let mangled := mangledRust source indentKept
  withTestHost context [("init.lean", reindentText mangled)] fun session => do
      session.ask [.reload]
      check session source mangled

/-- The text the view shows after `load-<name>` and then the command
`command`, as its view line, and what the echo area says. -/
def _root_.Editor.Test.Linked.Session.loadedAndRan (session : Session) (name command : String) :
    IO (String × String) := do
  session.ask [.run ("load-" ++ name)]
  session.ask [.run command]
  return (lastViewLine (← session.sceneLines), ← session.echo)

/-- The checks of the core's indent levels through a host of the test
scheme (`withTestHost`), with the real elaborator, the real text binding
and the library's syntax service with Rust's shipped indents query, each
through a command of config's run by name: the rows re-indented, and the
level of a line opened, in a Rust buffer, in a buffer with no language and
in one whose language has no indents query. Which level a row gets is
`Editor/Indent.lean`'s, pinned by `ModelTest`'s indent checks and, over the
library, by `ContractTest`. -/
def indentChecks (context : Context) : List Check :=
  [{  name :=
        "in a Rust buffer whose indentation was mangled, a command of config's that applies the edits TextId.reindentEdits answers of every row gives text equal to the rustfmt-formatted fixture it came from, through the host's loop and the library's syntax tree, the rows inside its multi-line string and block comment kept; in a buffer with no language it is refused as a text with no syntax tree and the text is left, and in a JSON buffer, whose language has no indents query, as one with no query"
      run := do
        let said (refusal : SyntaxTreeError) := s!"refused: {refusal.describe}".quote
        -- A host of its own for the buffers of no Rust: the scratch buffer
        -- keeps the language a load gave it.
        let refused ←
          withIndentHost context fun session _ _ => do
              let (plain, plainEcho) ← session.loadedAndRan "plain" "reindent"
              let (json, jsonEcho) ← session.loadedAndRan "json" "reindent"
              unless
                showsText plain "    ab" 5 5 && plainEcho == said .notAttached &&
                  showsText json "[\n  1\n]" 4 4 &&
                  jsonEcho == said .noQuery do
                throw (IO.userError s!"{plain} {plainEcho} / {json} {jsonEcho}")
              return true
        let reindented ←
          withIndentHost context fun session source mangled => do
              let (line, _) ← session.loadedAndRan "mangled" "reindent"
              unless showsText line source 0 0 do
                throw (IO.userError line)
              return mangled != source &&
                  indentKept.all fun row => (source.splitOn ("\n" ++ row ++ "\n")).length == 2
        return refused && reindented },
    { name :=
        "in a Rust buffer, TextId.openingLevel asked by a command of config's answers one level after an opening brace, above a closing brace and at the text's end with none, and two in a method of an impl at the text's end; in a buffer with no language it is refused as a text with no syntax tree, and in a JSON buffer as one with no indents query"
      run := do
        let said (refusal : SyntaxTreeError) := s!"refused: {refusal.describe}".quote
        let refused ←
          withIndentHost context fun session _ _ => do
              let (_, plain) ← session.loadedAndRan "plain" "opening"
              let (_, json) ← session.loadedAndRan "json" "opening"
              unless plain == said .notAttached && json == said .noQuery do
                throw (IO.userError s!"{plain} / {json}")
              return true
        let levels ←
          withIndentHost context fun session _ _ => do
              let (_, closed) ← session.loadedAndRan "closed" "opening"
              let (_, eof) ← session.loadedAndRan "eof" "opening"
              let (_, nested) ← session.loadedAndRan "nested-eof" "opening"
              unless
                closed == "level 1".quote && eof == "level 1".quote && nested == "level 2".quote do
                throw (IO.userError s!"{closed} / {eof} / {nested}")
              return true
        return refused && levels }]

end ConfigTest
