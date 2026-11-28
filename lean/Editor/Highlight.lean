import Editor.Command
import Editor.Face.Vocabulary
import Editor.Mode

/-!
# Highlighting a buffer's text from its major mode

What a major mode with a syntax tree (`Mode.SyntaxTree`, `Editor/Mode.lean`)
asks of the library's syntax service when it becomes a buffer's major mode,
and the rule that says which face each of a highlights query's captures is
drawn in. Parsing, running the query over what is shown and drawing it are
the library's: highlights reach the display there and never pass through
Lean (`crates/editor-ffi/src/syntax.rs`, "Highlights"). What crosses is a
query and one face, or none, for each of its captures.

## The capture-to-face rule (`faceOf`)

The shipped default (`defaultFaces`) maps each capture name `c` of the face
vocabulary's syntax captures (`Face.syntaxCaptures`,
`Editor/Face/Vocabulary.lean`) to the face `syntax.c`. It is computed from
that list, not copied, so it cannot drift from the vocabulary. A mode's
config (`Mode.SyntaxTree.captures`) is a mapping over it: the mapping a
capture is looked up in is config's entries, then the default's.

1. An entry for the capture's full name gives its face, and an entry of
   `none` draws nothing and stops the fallback.
2. Otherwise, a dotted name (`keyword.control`) takes the entry of its first
   component (`keyword`).
3. Otherwise the capture draws nothing (Rust's shipped `@escape`, `@label`).

So config can override any mapping, a first component's too, which then
reaches every dotted capture under it that has no entry of its own. The
fallback is to the first component only: `a.b.c` does not fall back to
`a.b` (an open question, `docs/design/rust-library.md`).

`faces` is `faceOf` over a query's capture names, in order: the table that
crosses (`SyntaxTree.highlight`).

## Entering a major mode with a syntax tree (`enter`)

The loop runs it, inside the command that set the mode, before the new
lineage's on-enter actions (`Editor/Command/Dispatch.lean`). The `code`
mode's tree is its buffer's language's (`Editor/Language.lean`), which the
loop hands here as it hands any mode's.

0. `refreshAfter` with config's syntax refresh delay (`syntaxRefreshDelay`,
   `Editor/Setup.lean`), or `defaultRefreshDelay`: how long a text goes
   unchanged after an edit before the library parses it whole, so its tree
   is exact. It is for every text, so a reload changes it from the next
   buffer whose mode is entered.

Every query is the tree's own: a language entry's, or the one read from a
declared grammar's directory (`Language.Grammar.treeOf`). The library
compiles in no grammar and ships no query, so the port's `shippedQuery` is
never asked (the task `syntax-port-drop-shipped-query`). A tree that names
no highlights query runs none of the steps below, steps 0 and 1 included:
the text is detached, as after a refusal, so nothing of the mode before is
drawn, and ``highlights: `<mode>`: <noHighlights>`` is said in the echo
area.

Then, with a snapshot of the buffer's text (`TextId.withSnapshot`):

1. `attach` the snapshot with the grammar;
2. the query's source: the tree's highlights;
3. `compile` it, and read its `captureNames`;
4. `highlight` the snapshot with the query and `faces` of the mode's
   mapping;
5. `release` the query: the library's highlighter keeps it.

A refusal from the syntax tree port stops the steps, detaches the text, and
is said in the echo area, ``highlights: `<mode>`: <refusal>``. The mode is
still set and the command is not refused: a query of config's that does not
compile keeps no buffer out of its mode.

After highlights that succeeded, four more steps, each skipped when the
tree names no query of its kind:

6. **Injections.** The tree's injections query (none skips steps 6 and
   7): compiled, `inject`ed, released.
7. **Languages.** For each grammar the library has (`grammars`), an
   `injectLanguage` of its name: its highlights query, in the faces of the
   mode's mapping over its capture names (`faces`), so config's capture
   faces reach embedded code too, and its injections query, if it has one;
   both released after. For the mode's grammar both are the mode's own.
   For any other they are those of the tree `injected` gives for the
   grammar's name; a tree that names no highlights gives no language. The
   dispatch passes the resolved tree of the language entry naming the
   grammar (`Language.Grammar.injectedTreeOf`,
   `Editor/Language/Grammar.lean`): declared queries filled in, the
   entry's own winning, so a declared or package-shipped grammar's fences
   are drawn with the queries read from its directory. A grammar for which
   `injected` gives none (declared and awaiting its answer, or refused and
   no longer listed) gives no language; once the answer is recorded,
   injecting again (below) gives it one. With no `injected`, each
   grammar's bare tree, which names no query, so no language. Names are
   grammar names: an alias (`rs`) names nothing.
8. **Text objects.** The text objects query: compiled, kept
   (`keep .textObjects`), released.
9. **Indents.** The same, with `.indents`.

A refusal in steps 6 to 9 stops its own step alone and is said in the echo
area, under the mode's name: ``injections: `<mode>`: <refusal>`` for steps
6 and 7, ``text objects: `<mode>`: <refusal>`` for step 8 and
``indents: `<mode>`: <refusal>`` for step 9. The highlights stay, and the
text is not detached. Step 7 compiles a highlights query for each grammar
the library has, once each time a mode with injections is set, not for
each key; caching compiled queries is an open question.

The detach is what keeps the mode before from being drawn: the steps run
over what that mode left, and a refused attach (a grammar the library lacks)
replaces nothing, while an attach with the same grammar keeps its parse and
its highlighter, which a query that then does not compile never replaces. So
a refused mode's text is drawn plain, as the echo area says, whatever mode it
replaced. Detaching a text that is not attached does nothing.

`leave` detaches the text, when a major mode with no syntax tree replaces
one with a syntax tree. A mode that says nothing of a syntax tree, set over
one that said nothing either, asks the port nothing.

**Injecting again** (`reinject`) runs steps 6 and 7 alone over a text its
mode already highlights, with the trees `injected` now gives: the
dispatch runs it when the `register-grammars` job's command has recorded
its answers, for each highlighted buffer it does not highlight again from
scratch, so a fence of a grammar that was awaiting its answer, or that the
answer replaced, takes the queries the answer gives
(`Editor/Command/Dispatch.lean`, "Highlighting again"). Nothing is
detached and the highlights stay. A text that is not attached is asked
nothing more and nothing is said, since its refusal was said when its mode
was entered; any other refusal is said as step 6's.

Pinned by `ModelTest.highlightFaceChecks` (the rule, pure),
`ModelTest.highlightEnterChecks` (on the editor's models, through the
loop's dispatch) and `ModelTest.highlightInjectedChecks` (step 7's
languages of grammars registered at run time, driven from a config's
install through the `register-grammars` job's command).
-/

namespace Editor.Highlight

/-- How long a text goes unchanged after an edit, in milliseconds, before
the syntax service parses it whole again, when config sets nothing
(`syntaxRefreshDelay`, `Editor/Setup.lean`): the default users see. -/
def defaultRefreshDelay : Nat :=
  500

/-- The shipped default: each capture name of the face vocabulary's syntax
captures, and its face, `syntax.` and the name. -/
def defaultFaces : List (String × FaceName) :=
  Face.syntaxCaptures.toList.map fun (capture, _) => (capture, ⟨s!"syntax.{capture}"⟩)

/-- The face the capture `capture` is drawn in, by config's mapping `config`
over the shipped default (the rule of the module docs); `none` when it draws
nothing. -/
def faceOf (config : List (String × Option FaceName)) (capture : String) : Option FaceName :=
  let mapping := config ++ defaultFaces.map fun (name, face) => (name, some face)
  let entry (name : String) : Option (Option FaceName) := (mapping.find? (·.1 == name)).map (·.2)
  match entry capture with
  | some face => face
  | none =>
    match capture.splitOn "." with
    | first :: _ :: _ => (entry first).join
    | _ => none

/-- The face of each of a query's capture names `names`, in order, by
config's mapping `config` (`faceOf`): the table `SyntaxTree.highlight`
takes. -/
def faces (config : List (String × Option FaceName)) (names : Array String) :
    Array (Option FaceName) :=
  names.map (faceOf config)

/-- Puts `text` in the echo area: the state request the API's `message`
makes (`Editor/Api.lean`), asked here, below the API, since the loop's
dispatch runs this module's steps. -/
private def say (text : String) : EditorM Unit :=
  ExceptT.lift (Program.request (port := editorPort) (.state (.message text)))

/-- Config's syntax refresh delay, asked of the registry as the API's
`RegistryRequest.ask` asks it, here below the API. -/
private def refreshDelay : EditorM (Option Nat) :=
  ExceptT.lift (Program.request (port := editorPort) (.registry .syntaxRefreshDelay))

/-- What is said, after ``highlights: `<mode>`: ``, when a major mode's
tree names no highlights query (the module docs). -/
def noHighlights : String :=
  "its tree names no highlights query"

/-- `run` with `query`, compiled from `source` for `grammar`, released after
it, whether `run` was refused or not. -/
def withQuery {α : Type} (grammar source : String) (run : QueryId → SyntaxTreeM α) :
    SyntaxTreeM α := do
  let query ← SyntaxTree.compile grammar source
  try
    let result ← run query
    SyntaxTree.release query
    return result
  catch refusal =>
    SyntaxTree.release query
    throw refusal

/-- Steps 6 and 7 of the module docs: the text's injections, and a language
for each grammar the library has, of the tree `injected` gives for its
name. -/
def injections (snapshot : SnapshotId) (syntaxTree : Mode.SyntaxTree)
    (injected : String → Option Mode.SyntaxTree := fun grammar => some { grammar }) :
    SyntaxTreeM Unit := do
  let some source := syntaxTree.injections | return
  withQuery syntaxTree.grammar source fun query => SyntaxTree.inject snapshot query
  for grammar in ← SyntaxTree.grammars do
    let own := grammar == syntaxTree.grammar
    let some tree := if own then some syntaxTree else injected grammar | continue
    let some highlights := tree.highlights | continue
    let injections := if own then some source else tree.injections
    withQuery grammar highlights fun query => do
        let names ← SyntaxTree.captureNames query
        let languageFaces := faces syntaxTree.captures names
        match injections with
        | none =>
          SyntaxTree.injectLanguage snapshot grammar query languageFaces none
        | some injections =>
          withQuery grammar injections fun own =>
              SyntaxTree.injectLanguage snapshot grammar query languageFaces (some own)

/-- Step 8 or 9 of the module docs: the text keeps its query of `kind`, from
the tree's own source `own`; nothing when it has none. -/
def keep (snapshot : SnapshotId) (syntaxTree : Mode.SyntaxTree) (own : Option String)
    (kind : QueryKind) : SyntaxTreeM Unit := do
  let some source := own | return
  withQuery syntaxTree.grammar source fun query => SyntaxTree.keep snapshot kind query

/-- Steps 6 to 9 of the module docs, after highlights that succeeded, each
refusal said in the echo area under the mode's name `mode` and stopping its
own step alone; the injected languages' trees by grammar name from
`injected`. -/
def structural (mode : String) (snapshot : SnapshotId) (syntaxTree : Mode.SyntaxTree)
    (injected : String → Option Mode.SyntaxTree := fun grammar => some { grammar }) :
    EditorM Unit := do
  let steps : List (String × SyntaxTreeM Unit) :=
    [("injections", injections snapshot syntaxTree injected),
      ("text objects", keep snapshot syntaxTree syntaxTree.textObjects .textObjects),
      ("indents", keep snapshot syntaxTree syntaxTree.indents .indents)]
  for (what, step) in steps do
    if let .error refusal← SyntaxTree.lift step then
      say s!"{what}: `{mode}`: {refusal.describe}"

/-- Steps 6 and 7 of the module docs again, alone, for the text `text`
that a major mode called `mode` with `syntaxTree` already highlights: its
injections, and a language for each grammar the library has, of the tree
`injected` gives for its name ("Injecting again", in the module docs).
The highlights and the parse stay. A text that is not attached (its attach
was refused when the mode was entered, and said then) is asked nothing
more and nothing is said; any other refusal is said as step 6's. -/
def reinject (mode : String) (text : TextId) (syntaxTree : Mode.SyntaxTree)
    (injected : String → Option Mode.SyntaxTree) : EditorM Unit :=
  text.withSnapshot fun snapshot => do
    match ← SyntaxTree.lift (injections snapshot syntaxTree injected) with
    | .ok () | .error .notAttached =>
      pure ()
    | .error refusal =>
      say s!"injections: `{mode}`: {refusal.describe}"

/-- What setting a major mode with `syntaxTree` asks of the syntax tree port
for its text `text` (the steps of the module docs): attached with the
grammar, and highlighted with the query in the faces `faces` gives; or,
refused, detached, so nothing of the mode before is drawn, and said in the
echo area under the mode's name `mode`. A tree that names no highlights
is detached, asked nothing else, and says `noHighlights` under the mode's
name. Each
injected language takes the tree `injected` gives for its grammar's name
(step 7); by default, the bare tree of the grammar, which names no query.
Never refused itself. -/
def enter (mode : String) (text : TextId) (syntaxTree : Mode.SyntaxTree)
    (injected : String → Option Mode.SyntaxTree := fun grammar => some { grammar }) :
    EditorM Unit := do
  let some source := syntaxTree.highlights
    |
    do
      text.withSnapshot fun snapshot => discard (SyntaxTree.lift (SyntaxTree.detach snapshot))
      say s!"highlights: `{mode}`: {noHighlights}"
  let delay := (← refreshDelay).getD defaultRefreshDelay
  discard (SyntaxTree.lift (SyntaxTree.refreshAfter delay))
  text.withSnapshot fun snapshot => do
      let steps : SyntaxTreeM Unit := do
        SyntaxTree.attach snapshot syntaxTree.grammar
        let query ← SyntaxTree.compile syntaxTree.grammar source
        try
          let names ← SyntaxTree.captureNames query
          SyntaxTree.highlight snapshot query (faces syntaxTree.captures names)
        catch refusal =>
          SyntaxTree.release query
          throw refusal
        SyntaxTree.release query
      match ← SyntaxTree.lift steps with
      | .ok () =>
        structural mode snapshot syntaxTree injected
      | .error refusal =>
        discard (SyntaxTree.lift (SyntaxTree.detach snapshot))
        say s!"highlights: `{mode}`: {refusal.describe}"

/-- What setting a major mode with no syntax tree over one with a syntax
tree asks of the syntax tree port for its text `text`: it is detached, which
drops its highlights. -/
def leave (text : TextId) : EditorM Unit :=
  text.withSnapshot fun snapshot => discard (SyntaxTree.lift (SyntaxTree.detach snapshot))

/-- The faces `text` is drawn in under `syntaxTree`, as a readout: the
captures over the whole text of the tree's highlights query, each
capture's face by the tree's mapping (`faceOf`), with its range; a capture
that draws nothing is left out. None when the text is not attached, or the
tree names no highlights query; any other refusal of the port is handed
back. What
the headless mode's `highlights` prints (`Editor/Headless.lean`). -/
def capturedFaces (text : TextId) (syntaxTree : Mode.SyntaxTree) :
    EditorM (Except SyntaxTreeError (Option (Array (FaceName × Nat × Nat)))) := do
  let length := (← text.read).utf8ByteSize
  text.withSnapshot fun snapshot => do
      let read : SyntaxTreeM (Option (Array (FaceName × Nat × Nat))) := do
        let some source := syntaxTree.highlights | return none
        withQuery syntaxTree.grammar source fun query => do
            let names ← SyntaxTree.captureNames query
            let captures ← SyntaxTree.captures snapshot query 0 length
            return some <|
                captures.filterMap fun captured => do
                  let name ← names[captured.capture]?
                  let face ← faceOf syntaxTree.captures name
                  return (face, captured.start, captured.stop)
      match ← SyntaxTree.lift read with
      | .error .notAttached =>
        return .ok none
      | answer =>
        return answer

end Editor.Highlight
