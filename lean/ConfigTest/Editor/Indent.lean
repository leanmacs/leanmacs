import ConfigTest.Check
import Editor.Evil.Operators
import Editor.File.Model
import Editor.Headless
import Editor.InputScheme.Vim
import Editor.SyntaxTree
import Editor.Test.Linked.Host
import Editor.Test.Linked.Keys
import Editor.Test.Linked.Lines
import Editor.Test.Linked.Shipped
import Editor.Test.Linked.Vim

/-!
# Config tests: `Editor/Indent.lean`

The tests of `Editor/Indent.lean`: `indentChecks`, on the syntax fixtures. The
root module `ConfigTest` runs them; its module doc says what each shows.
-/

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- The rows of the Rust indent fixture (`tests/syntax/rust/indent.rs`) inside
its multi-line string and block comment, which the indent rule keeps: found
by their content, never by their number. -/
def indentKept : List String :=
  ["not indented by the rule\";", "       comment */"]

/-- `source` with the indentation of its rows mangled: a row of `kept`, and
the last, empty after the final line feed, stays as it is; a blank row
becomes three spaces; any other row loses its leading blanks and gains, by
its number, nothing, two spaces, a tab or six spaces. Made in code from the
fixture, so no second fixture can drift from it. -/
def mangledRust (source : String) (kept : List String) : String :=
  let lines := source.splitOn "\n"
  "\n".intercalate <|
    lines.zipIdx.map fun (line, row) =>
      if kept.contains line || row + 1 == lines.length then line
      else
        let content := (line.dropWhile fun char => char == ' ' || char == '\t').toString
        if content.isEmpty then "   " else ["", "  ", "\t", "      "].getD (row % 4) "" ++ content

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

/-- Runs `check` against a host of the Vim scheme that ships
(`withVimHost`) over `indentText` of the mangled Rust indent fixture, with
the config loaded: handed the fixture's text and the mangled one. -/
def withIndentHost (context : Context) (check : Session → String → String → IO Bool) : IO Bool := do
  let source ← IO.FS.readFile (context.syntaxFixtures / "rust" / "indent.rs")
  let mangled := mangledRust source indentKept
  withVimHost context [("init.lean", indentText mangled)] fun session => do
      session.ask [.reload]
      check session source mangled

/-- Whether the view line `line` shows the text `text` and one selection
from `anchor` to `head`. -/
def showsText (line text : String) (anchor head : Nat) : Bool :=
  (line.splitOn s!"{text.quote}, scroll").length == 2 &&
    (line.splitOn s!"selections {anchor}..{head},").length == 2

/-- The view line after `load-<name>` and then the keys `keys`. -/
def _root_.Editor.Test.Linked.Session.loadedAndTyped (session : Session) (name keys : String) :
    IO String := do
  session.ask [.run ("load-" ++ name)]
  session.typed keys
  return lastViewLine (← session.sceneLines)

/-- The checks of `=` and of indented new lines through a host of the Vim
scheme that ships (`withVimHost`), with the real elaborator, the real text
binding and the library's syntax service with Rust's shipped indents query,
each through keys: the acceptance criteria of `=` and of `RET`, `o` and
`O` in a Rust buffer, and in a buffer with no language and one whose
language has no indents query. Which level a row gets is
`Editor/Indent.lean`'s, pinned by `ModelTest`'s indent checks and, over the
library, by `ContractTest`. -/
def indentChecks (context : Context) : List Check :=
  [{  name :=
        "in a Rust buffer whose indentation was mangled, g g = G gives text equal to the rustfmt-formatted fixture it came from, with the cursor on the first row's first non-blank, through the host's loop and the library's syntax tree; the rows inside its multi-line string and block comment, which the rule would indent by four spaces, keep theirs"
      run :=
        withIndentHost context fun session source mangled => do
          let line ← session.loadedAndTyped "mangled" "g g = G"
          let leading (row : String) := (row.takeWhile (· == ' ')).toString
          unless showsText line source 0 0 do
            throw (IO.userError line)
          return mangled != source &&
              indentKept.all (fun row => (source.splitOn ("\n" ++ row ++ "\n")).length == 2) &&
              indentKept.all (leading · != "    ") },
    { name :=
        "= keeps the leading whitespace of a row inside a multi-line string and inside a block comment, and re-indents the rows around them"
      run :=
        withIndentHost context fun session _ _ => do
          let line ← session.loadedAndTyped "strings" "g g = G"
          let indented := "fn f() {\n    let s = \"a\n   b\";\n    /* c\n     d */\n    s\n}\n"
          unless showsText line indented 0 0 do
            throw (IO.userError line)
          return true },
    { name :=
        "in a Rust buffer, = a f inside the second of two mangled functions re-indents exactly that function's rows: the first function and the struct above keep their mangled indentation byte for byte"
      run :=
        withIndentHost context fun session _ _ => do
          let line ← session.loadedAndTyped "two-fns" "= a f"
          let indented :=
            "struct S;\n\nfn one() {\nlet a = 1;\n        a\n}\n\nfn two() {\n    let b = 2;\n    b\n}\n"
          let some at_ := offsetOf indented "fn two" | return false
          unless showsText line indented at_ at_ do
            throw (IO.userError line)
          return true },
    { name :=
        "in a Rust buffer, one = a f is undone by one u, which gives back the whole mangled text, and . then re-indents the other function, leaving the first as u left it"
      run :=
        withIndentHost context fun session _ _ => do
          discard <| session.loadedAndTyped "two-fns" "= a f u"
          let undone := lastViewLine (← session.sceneLines)
          session.typed "g g j j j ."
          let repeated := lastViewLine (← session.sceneLines)
          let mangled :=
            "struct S;\n\nfn one() {\nlet a = 1;\n        a\n}\n\nfn two() {\nlet b = 2;\n        b\n}\n"
          let some letB := offsetOf mangled "let b" | return false
          let indented :=
            "struct S;\n\nfn one() {\n    let a = 1;\n    a\n}\n\nfn two() {\nlet b = 2;\n        b\n}\n"
          let some fnOne := offsetOf indented "fn one" | return false
          unless showsText undone mangled letB letB && showsText repeated indented fnOne fnOne do
            throw (IO.userError s!"{undone} / {repeated}")
          return true },
    { name :=
        "in a Rust buffer, A RET after an opening brace starts the new line one indent unit deeper than the brace's line: above a closing brace, at the text's end with none, and two deep in a method of an impl at the text's end"
      run :=
        withIndentHost context fun session _ _ => do
          let closed ← session.loadedAndTyped "closed" "A RET"
          session.typed "<Escape>"
          let eof ← session.loadedAndTyped "eof" "A RET"
          session.typed "<Escape>"
          let nested ← session.loadedAndTyped "nested-eof" "A RET"
          let closedText := "fn main() {\n    \n    let x = 1;\n}\n"
          let nestedText := "impl S {\n    fn one(&self) {\n        "
          unless
            showsText closed closedText 16 16 && showsText eof "fn main() {\n    " 16 16 &&
              showsText nested nestedText nestedText.utf8ByteSize nestedText.utf8ByteSize do
            throw (IO.userError s!"{closed} / {eof} / {nested}")
          return true },
    { name :=
        "in a Rust function body, o opens a row at the body's level, and typing if a { and RET there starts the next row a level deeper, though the if is not closed"
      run :=
        withIndentHost context fun session _ _ => do
          let line ← session.loadedAndTyped "mid" "o i f SPC a SPC { RET"
          let typed := "fn main() {\n    x();\n    if a {\n        "
          unless showsText line (typed ++ "\n}\n") typed.utf8ByteSize typed.utf8ByteSize do
            throw (IO.userError line)
          return true },
    { name :=
        "in a Rust method's body, o and O on a statement start the new row at the body's level, and O on the method's closing brace does too"
      run :=
        withIndentHost context fun session _ _ => do
          let below ← session.loadedAndTyped "method" "o"
          session.typed "<Escape>"
          let above ← session.loadedAndTyped "method" "O"
          session.typed "<Escape>"
          let closing ← session.loadedAndTyped "method-closing" "O"
          let opened (needle : String) : Option (String × Nat) := do
            let at_ ← offsetOf rustObjectsText needle
            let bar := at_ + needle.utf8ByteSize + 8
            return ((rustObjectsText.take (at_ + needle.length)).toString ++ "        \n" ++
                  (rustObjectsText.drop (at_ + needle.length)).toString,
                bar)
          let some (belowText, belowBar) := opened "let x = 1;\n" | return false
          let some (aboveText, aboveBar) := opened "u8 {\n" | return false
          let some (closingText, closingBar) := opened "        x\n" | return false
          unless
            showsText below belowText belowBar belowBar &&
              showsText above aboveText aboveBar aboveBar &&
              showsText closing closingText closingBar closingBar do
            throw (IO.userError s!"{below} / {above} / {closing}")
          return true },
    { name :=
        "in a buffer with no language = = leaves the text and says the buffer has no syntax tree, and A RET, o and O insert bare line breaks as before; in a JSON buffer, whose language has no indents query, = = says so and A RET inserts a bare line break"
      run :=
        withIndentHost context fun session _ _ => do
          let plain ← session.loadedAndTyped "plain" "= ="
          let (plainEcho, _) ← session.scene
          session.typed "A RET <Escape> o <Escape> O <Escape>"
          let opened := lastViewLine (← session.sceneLines)
          let json ← session.loadedAndTyped "json" "= ="
          let (jsonEcho, _) ← session.scene
          session.typed "A RET"
          let broken := lastViewLine (← session.sceneLines)
          let said (refusal : SyntaxTreeError) :=
            s!"{Vim.operateCommand}: {Evil.cannotIndent refusal}".quote
          unless
            showsText plain "    ab" 5 5 && plainEcho == said .notAttached &&
              (opened.splitOn s!"{"    ab\n\n\n".quote}, scroll").length == 2 &&
              showsText json "[\n  1\n]" 4 4 &&
              jsonEcho == said .noQuery &&
              showsText broken "[\n  1\n\n]" 6 6 do
            throw (IO.userError s!"{plain} {plainEcho} / {opened} / {json} {jsonEcho} / {broken}")
          return true }]

end ConfigTest
