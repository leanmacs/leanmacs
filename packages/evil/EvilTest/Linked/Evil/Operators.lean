import Editor.File.Model
import Editor.RealHost
import Editor.Test.Linked.Host
import Editor.Test.Linked.Keys
import Editor.Test.Linked.Lines
import Editor.Test.Linked.Shipped
import Editor.Test.Linked.Syntax
import Evil.Operators
import EvilTest.Check
import EvilTest.Linked.Support.Vim

/-!
# Linked tests: `Evil/Operators.lean`

The tests of `Evil/Operators.lean` through a host: `evilIndentChecks`,
the indent operator `=` and evil's indented new lines (`Evil.lean`,
"Opening a line"), on the syntax fixtures, through a host of the Vim scheme
that ships over the real syntax tree binding. The root module `EvilTest.Linked`
runs them; its module doc says what each shows.

A module of the wiring set, declared in place (`AGENTS.md`, "Deterministic
concurrency in tests"; `docs/dev-practices/real-thread-checks.md`): its one
check is a wiring check of the shipped Rust `indents` query over the
library's syntax service, which the syntax model does not hold (W87).
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.EvilTest.Linked.Evil.Operators : Editor.WiringSet :=
  .wiring
    "the library's syntax service with the shipped Rust indents query, through the Vim scheme's keys"
    "the syntax model holds JSON alone, so the shipped Rust query is reached only over the real binding (W87)"

namespace EvilTest.Linked

open Editor
open Editor.Test.Linked

/-- The byte offset of the first occurrence of `needle` in `text`, or 0 when
it holds none. -/
def cursorAt (text needle : String) : Nat :=
  (offsetOf text needle).getD 0

/-- The texts the indent checks load, each with where the cursor goes and
the language its buffer is set to, if any (`indentText`): the mangled Rust
fixture `mangled`, and texts written here. -/
def indentFixtures (mangled : String) : List (String × String × Nat × Option String) :=
  let twoFns :=
    "struct S;\n\nfn one() {\nlet a = 1;\n        a\n}\n\nfn two() {\nlet b = 2;\n        b\n}\n"
  let mid := "fn main() {\n    x();\n}\n"
  let nested := "impl S {\n    fn one(&self) {"
  [("mangled", mangled, 0, some "rust"), ("two-fns", twoFns, cursorAt twoFns "let b", some "rust"),
    ("strings", "fn f() {\nlet s = \"a\n   b\";\n/* c\n     d */\n        s\n}\n", 0, some "rust"),
    ("closed", "fn main() {\n    let x = 1;\n}\n", 0, some "rust"),
    ("eof", "fn main() {", 0, some "rust"),
    ("nested-eof", nested, cursorAt nested "fn one", some "rust"),
    ("mid", mid, cursorAt mid "x()", some "rust"),
    ("method", rustObjectsText, cursorAt rustObjectsText "let x", some "rust"),
    ("method-closing", rustObjectsText, cursorAt rustObjectsText "}\n}\n", some "rust"),
    ("plain", "    ab", 5, none), ("json", "[\n  1\n]", 4, some "json")]

/-- A config whose `setup` registers, for each of `indentFixtures mangled`,
the command `load-<name>`: it puts the fixture's text in the scratch
buffer's text, in place of what it held, and the cursor where the fixture
says, and then, for a fixture with a language, records the language and
makes `code` the buffer's major mode, so the text is parsed as the language
says. -/
def indentText (mangled : String) : String :=
  let commands :=
    (indentFixtures mangled).map fun (name, text, cursor, language) =>
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

def setup : SetupM Unit := do
" ++
    "\n".intercalate commands ++
    "\n"

/-- Runs `check` against a real host of the Vim scheme that ships
(`withRealVimHost`) over `indentText` of the mangled Rust indent fixture,
with the config loaded and the test grammars of `grammars`' directory
registered by the host's `register-grammars` job, so the Rust language's
tree takes its queries from there: handed the fixture's text and the
mangled one. The
host runs a loop thread of its own, since the library's syntax service
hands its parses back over the library's editor queue, which a stepped
host never pulls. -/
private def withEvilIndentHost (context : HostContext) (grammars : TestGrammars)
    (syntaxFixtures : System.FilePath) (check : RealSession → String → String → IO Bool) :
    IO Bool := do
  let source ← IO.FS.readFile (syntaxFixtures / "rust" / "indent.rs")
  let mangled := mangledRust source indentKept
  withRealVimHost context grammars [("init.lean", indentText mangled)] fun session => do
      session.ask [.reload]
      if let .error why← session.testGrammarsRegistered then
        throw (IO.userError why)
      check session source mangled

/-- The view line after `load-<name>` and then the keys `keys`. -/
def _root_.Editor.Test.Linked.Session.loadedAndTyped (session : Session) (name keys : String) :
    IO String := do
  session.ask [.run ("load-" ++ name)]
  session.typed keys
  return lastViewLine (← session.sceneLines)

/-- The checks of `=` and of indented new lines through a host of the Vim
scheme that ships (`withRealVimHost`), with the real elaborator, the real text
binding and the library's syntax service with Rust's shipped indents query,
through keys: `g g =` over a mangled Rust buffer. It asserts the wiring
alone, that the shipped query is reached over the library and answers:
`=` over its other motions and text objects, its undo, the levels `RET`,
`o` and `O` open at, and the refusals in a buffer with no language and in
one whose language has no indents query are `EvilTest.evilIndentChecks`'
(`EvilTest/Evil/Operators.lean`, over the JSON model tree); which level a
row gets is `Editor/Indent.lean`'s, pinned by `ModelTest`'s indent checks
and, over the library, by `ContractTest/Editor/SyntaxTree/Real.lean`'s
indents checks. -/
def evilIndentChecks (context : HostContext) (grammars : TestGrammars)
    (syntaxFixtures : System.FilePath) : List Check :=
  [{  name :=
        "in a Rust buffer whose indentation was mangled, g g = G gives text equal to the rustfmt-formatted fixture it came from, with the cursor on the first row's first non-blank, through the host's loop and the library's syntax tree; the rows inside its multi-line string and block comment, which the rule would indent by four spaces, keep theirs"
      run :=
        withEvilIndentHost context grammars syntaxFixtures fun session source mangled => do
          let line ← session.loadedAndTyped "mangled" "g g = G"
          let leading (row : String) := (row.takeWhile (· == ' ')).toString
          unless showsText line source 0 0 do
            throw (IO.userError line)
          return mangled != source &&
              indentKept.all (fun row => (source.splitOn ("\n" ++ row ++ "\n")).length == 2) &&
              indentKept.all (leading · != "    ") }]

end EvilTest.Linked
