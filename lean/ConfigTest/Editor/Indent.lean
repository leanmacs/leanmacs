import ConfigTest.Check
import ConfigTest.Support.Shipped
import Editor.RealHost
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

A module of the wiring set, declared in place (`AGENTS.md`, "Deterministic
concurrency in tests"; `docs/dev-practices/real-thread-checks.md`): every
check it holds is one. **The real adapter.** The library's syntax service
with Rust's shipped `indents` query, through a host
(`withRealSyntaxTestHost`). **Why.** The syntax model holds JSON alone, so
the shipped Rust query is reached only over the real binding. Its one
check asserts the wiring: the refusals are `ModelTest.Editor.Indent`'s,
and the levels `ContractTest/Editor/SyntaxTree/Real.lean`'s.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`): every check
it holds is a wiring check of the library's syntax service. -/
def wiringSet.ConfigTest.Editor.Indent : Editor.WiringSet :=
  .wiring "the library's syntax service with the shipped Rust indents query (RealSyntaxTree)" "the syntax model holds JSON alone, so the shipped Rust query is reached only over the real binding"

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

-- inferred-waits W89: stays (A5: the indent checks' subject is the library's shipped indents query over the real syntax service)
set_option linter.inferredWait false in
/-- Runs `check` against a real host of the test scheme with the real syntax
binding (`withRealSyntaxTestHost`) over `reindentText` of the mangled Rust indent fixture, with the config
loaded: handed the fixture's text and the mangled one. -/
private def withIndentHost (context : Context) (check : RealSession → String → String → IO Bool) :
    IO Bool := do
  let source ← IO.FS.readFile (context.syntaxFixtures / "rust" / "indent.rs")
  let mangled := mangledRust source indentKept
  withRealSyntaxTestHost context [("init.lean", reindentText mangled)] fun session => do
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
scheme (`withRealSyntaxTestHost`), with the real elaborator, the real text binding
and the library's syntax service with Rust's shipped indents query, each
through a command of config's run by name: the rows of a mangled Rust
buffer re-indented. Which level a row gets, and the refusals, are
`Editor/Indent.lean`'s, pinned by `ModelTest`'s indent checks and, over the
library, by `ContractTest`. -/
def indentChecks (context : Context) : List Check :=
  [{  name :=
        "in a Rust buffer whose indentation was mangled, a command of config's that applies the edits TextId.reindentEdits answers of every row gives text equal to the rustfmt-formatted fixture it came from, through the host's loop and the library's syntax tree, the rows inside its multi-line string and block comment kept"
      run :=
        -- Wiring only: the shipped Rust indents query is reached over the
        -- library's syntax service and answers. The refusals of a text with
        -- no syntax tree and of one with no indents query are
        -- `ModelTest.Editor.Indent`'s; the levels a row gets,
        -- `ContractTest/Editor/SyntaxTree/Real.lean`'s (its indents
        -- checks) and `ModelTest/Editor/Indent.lean`'s.
        withIndentHost context fun session source mangled => do
          let (line, _) ← session.loadedAndRan "mangled" "reindent"
          unless showsText line source 0 0 do
            throw (IO.userError line)
          return mangled != source &&
              indentKept.all fun row => (source.splitOn ("\n" ++ row ++ "\n")).length == 2 }]

end ConfigTest
