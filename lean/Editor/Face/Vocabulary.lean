import Editor.Scene

/-!
# The face vocabulary

The names of the faces a shipped theme defines (`vocabulary`), each with a
sentence: what is drawn in it, and by whom. A theme is a list of
definitions (`Editor/Face.lean`) and a scene names faces by name
(`Editor/Scene.lean`); a name nothing defines sets nothing, so a face drawn
and not defined is drawn in the faces under it, the default face's look. The
vocabulary is the list that keeps that from happening to a face the editor
draws: every shipped theme defines every name in it, and the completeness
check (`Themes.problems`, `Editor/Theme/Check.lean`) holds that it does.

- **What is drawn now.** The four names layout reads by itself (`default`,
  `selection`, `mode-line`, `echo-area`; `crates/editor-layout/src/face.rs`),
  the cursor face a scheme that names none draws in (`cursor`,
  `InputScheme.Report`), the shipped Vim scheme's cursor face and mode-line
  badge face of each of its states (`Vim.cursorFace`, `Vim.stateFace`;
  the cursor faces are marked `cursor`, and `cursorNames` lists them),
  the mode line's faces (`ModeLine.bufferFace`, `ModeLine.modifiedFace`,
  `ModeLine.changedFace`, `ModeLine.secondaryFace`, `ModeLine.inactiveFace`,
  `ModeLine.activeFace`, `Editor/ModeLine.lean`), the divider between tiled
  windows (`Loop.dividerFace`), the minibuffer's label
  (`Loop.promptFace`), the rows of the candidate list the minibuffer
  display draws (`Completion.Displays.candidateFace`, `chosenFace`,
  `matchFace`, `annotationFace`, `groupFace`,
  `packages/completion/Completion/Displays.lean`), the
  compile mode's locations by severity (`compilation.error`,
  `compilation.warning`, `compilation.note`; `Compile.Severity.face`), the
  matches of the last search (`Loop.searchMatchFace`), and the tab bar's
  chips (`TabBar.face`, `TabBar.selectedFace`, `Editor/TabBar.lean`).
- **The markup faces** (`markupEntries`), a group of their own beside
  `compilation.` and `cursor.`: `text.heading.1` to `text.heading.6`,
  `text.emphasis`, `text.strong`, `text.code-span`, `text.code-block`,
  `text.link`, `text.quote`, `text.list-marker` and `text.table-header`,
  drawn now in a markdown file opened as code, where markdown's captures
  name them (`Highlight.defaultFaces`, from `markupCaptures`), and
  `text.prose`, the proportional face of generated buffers' prose, declared
  ahead.
- **What is declared ahead.** The faces of features not built yet, so a
  shipped theme colours them before the feature lands: one `syntax.` face
  for each top-level name of tree-sitter's
  common highlight captures; diff, gutter and review faces; and a
  block header. A dotted capture such as `keyword.control` or
  `function.builtin` is not a vocabulary face: the rule that draws it in the
  face of its first component is `Highlight.faceOf`'s
  (`Editor/Highlight.lean`), whose default mapping is computed from
  `syntaxCaptures`.
- **A feature that draws a face not listed adds it here**, gives it a
  definition in the palette mapping (`Palette.theme`, `Editor/Face.lean`),
  and so in every shipped theme; the check fails until it has.
- Config may still name and define any other face. Nothing checks those.

Pinned by `ModelTest.faceVocabularyChecks`.
-/

namespace Editor.Face

/-- A face of the vocabulary. -/
structure Entry where
  /-- The face's name. -/
  name : FaceName
  /-- One sentence: what is drawn in it, and by whom. -/
  meaning : String
  /-- Whether a view's cursor is drawn in it (`cursorNames`). -/
  cursor : Bool := false
  deriving DecidableEq, Repr

/-- Each top-level name of tree-sitter's common highlight captures, with what
it is used for: the syntax faces are `syntax.` and each
(`syntaxEntries`). -/
def syntaxCaptures : Array (String × String) :=
  #[("attribute", "an attribute or annotation"), ("comment", "a comment"),
    ("constant", "a constant, builtin or not"), ("constructor", "a constructor"),
    ("embedded", "code embedded in another language"),
    ("function", "a function or method, where it is defined or called"), ("keyword", "a keyword"),
    ("module", "a module or namespace's name"), ("number", "a numeric literal"),
    ("operator", "an operator"), ("property", "a field or property"),
    ("punctuation", "a bracket, delimiter or separator"),
    ("string", "a string or character literal"), ("tag", "a markup tag"), ("type", "a type's name"),
    ("variable", "a variable or parameter")]

/-- The syntax faces declared ahead: `syntax.` and each top-level name of
tree-sitter's common highlight captures, with what it is used for. -/
def syntaxEntries : Array Entry :=
  syntaxCaptures.map fun (capture, what) =>
    { name := ⟨s!"syntax.{capture}"⟩
      meaning :=
        s!"Text tree-sitter captures as `{capture}`, {what}: drawn by the syntax-tree-sitter roadmap, declared ahead." }

/-- The markup faces: `text.` and a role of marked-up text, each drawn in a
code view where markdown's captures name it (`Highlight.defaultFaces`) and
in rendered markdown from the rich-text-display roadmap's phase 5, and the
prose face, declared ahead. -/
def markupEntries : Array Entry :=
  let drawn (what : String) (captures : String) : String :=
    s!"{what}: drawn in a markdown file opened as code, where the grammar captures it as {captures} (`Highlight.defaultFaces`), and in rendered markdown from the rich-text-display roadmap's phase 5."
  let headings :=
    (Array.range 6).map fun index =>
      let level := index + 1
      { name := ⟨s!"text.heading.{level}"⟩
        meaning := drawn s!"A heading of level {level}" s!"`text.heading.{level}`" : Entry }
  headings ++
    #[{ name := ⟨"text.emphasis"⟩, meaning := drawn "Emphasised text" "`text.emphasis`" },
      { name := ⟨"text.strong"⟩, meaning := drawn "Strong text" "`text.strong`" },
      { name := ⟨"text.code-span"⟩
        meaning :=
          drawn "An inline code span, in the monospace family so it stays monospace over prose"
            "`text.literal`" },
      { name := ⟨"text.code-block"⟩
        meaning :=
          drawn
            "A fenced or indented code block, in the monospace family so it stays monospace over prose"
            "`text.code-block`" },
      { name := ⟨"text.link"⟩
        meaning :=
          drawn "A link's text, label, destination or title" "`text.uri` or `text.reference`" },
      { name := ⟨"text.quote"⟩, meaning := drawn "A block quote" "`text.quote`" },
      { name := ⟨"text.list-marker"⟩
        meaning := drawn "A list item's marker" "`text.list-marker`" },
      { name := ⟨"text.table-header"⟩
        meaning := drawn "A table's header row" "`text.table-header`" },
      { name := ⟨"text.prose"⟩
        meaning :=
          "The proportional face a generated buffer's prose is drawn in, setting only the prose family (`Face.proseFamily`); no capture names it, so a markdown file opened as code stays monospace. The code faces set the monospace family, so code over it stays monospace. Declared ahead of the rich-text-display roadmap's phase 5." }]

/-- Each capture name of markdown's highlights queries that draws a markup
face, with that face: the block grammar's (the repository's query,
`crates/editor-syntax-treesitter/queries/markdown/highlights.scm`) and the
inline grammar's (the repository's query too,
`crates/editor-syntax-treesitter/queries/markdown_inline/highlights.scm`). Both
capture a link's title as `text.reference`, so `text.literal` is only a code
span. The shipped capture-to-face mapping
(`Highlight.defaultFaces`) is the syntax captures' then these. `text.prose`
has no capture: a markdown file opened as code stays monospace. -/
def markupCaptures : Array (String × FaceName) :=
  (Array.range 6).map
      (fun index => (s!"text.heading.{index + 1}", ⟨s!"text.heading.{index + 1}"⟩)) ++
    #[("text.emphasis", ⟨"text.emphasis"⟩), ("text.strong", ⟨"text.strong"⟩),
      ("text.literal", ⟨"text.code-span"⟩), ("text.code-block", ⟨"text.code-block"⟩),
      ("text.uri", ⟨"text.link"⟩), ("text.reference", ⟨"text.link"⟩),
      ("text.quote", ⟨"text.quote"⟩), ("text.list-marker", ⟨"text.list-marker"⟩),
      ("text.table-header", ⟨"text.table-header"⟩)]

/-- The vocabulary: every face a shipped theme defines, in order. -/
def vocabulary : Array Entry :=
  #[{   name := ⟨"default"⟩
        meaning :=
          "Under every other face, read by layout itself; its background is the paper and its foreground the ink." },
      { name := ⟨"selection"⟩, meaning := "The selections, drawn in it by layout itself." },
      { name := ⟨"mode-line"⟩
        meaning := "Under each field of a view's status line, read by layout itself." },
      { name := ⟨"echo-area"⟩
        meaning := "The echo area in the bottom row of the frame, read by layout itself." },
      { name := ⟨"cursor"⟩, cursor := true
        meaning :=
          "The cursor of a scheme that names no cursor face of its own, such as the test scheme (`InputScheme.Report`)." },
      { name := ⟨"cursor.normal"⟩, cursor := true
        meaning := "The cursor in the shipped Vim scheme's normal state (`Vim.cursorFace`)." },
      { name := ⟨"cursor.insert"⟩, cursor := true
        meaning := "The cursor in the shipped Vim scheme's insert state (`Vim.cursorFace`)." },
      { name := ⟨"cursor.visual"⟩, cursor := true
        meaning := "The cursor in the shipped Vim scheme's visual state (`Vim.cursorFace`)." },
      { name := ⟨"cursor.visual-line"⟩, cursor := true
        meaning := "The cursor in the shipped Vim scheme's visual-line state (`Vim.cursorFace`)." },
      { name := ⟨"cursor.minibuffer"⟩, cursor := true
        meaning :=
          "The cursor in the minibuffer's view, in the shipped Vim scheme's minibuffer state (`Vim.cursorFace`)." },
      { name := ⟨"mode-line.state.normal"⟩
        meaning :=
          "The mode line's badge of a view in the shipped Vim scheme's normal state (`Vim.stateFace`, the `state` segment)." },
      { name := ⟨"mode-line.state.insert"⟩
        meaning :=
          "The mode line's badge of a view in the shipped Vim scheme's insert state (`Vim.stateFace`, the `state` segment)." },
      { name := ⟨"mode-line.state.visual"⟩
        meaning :=
          "The mode line's badge of a view in the shipped Vim scheme's visual state (`Vim.stateFace`, the `state` segment)." },
      { name := ⟨"mode-line.state.visual-line"⟩
        meaning :=
          "The mode line's badge of a view in the shipped Vim scheme's visual-line state (`Vim.stateFace`, the `state` segment)." },
      { name := ⟨"mode-line.state.minibuffer"⟩
        meaning :=
          "The badge of the shipped Vim scheme's minibuffer state, which the minibuffer's view does not draw: kept so every state has one (`Vim.stateFace`)." },
      { name := ⟨"mode-line.buffer"⟩
        meaning :=
          "The buffer's name in a view's mode line, drawn by the `buffer` segment (`ModeLine.bufferFace`)." },
      { name := ⟨"mode-line.modified"⟩
        meaning :=
          "The mark the `modified` segment shows while the buffer is modified (`ModeLine.modifiedFace`)." },
      { name := ⟨"mode-line.changed"⟩
        meaning :=
          "The mark the `changed` segment shows while a check has found the buffer's file changed on disk (`ModeLine.changedFace`)." },
      { name := ⟨"mode-line.secondary"⟩
        meaning :=
          "What recedes in a mode line: the directory, the major mode, line:col and the position (`ModeLine.secondaryFace`)." },
      { name := ⟨"mode-line.active"⟩
        meaning :=
          "The row of the mode line of the selected window, whose background marks it (`ModeLine.activeFace`)." },
      { name := ⟨"mode-line.inactive"⟩
        meaning :=
          "Every field and the row of the mode line of a window that is not selected (`ModeLine.inactiveFace`)." },
      { name := ⟨"window-divider"⟩
        meaning :=
          "The divider between two tiled windows, filled in its foreground (`Loop.dividerFace`)." },
      { name := ⟨"minibuffer.prompt"⟩
        meaning :=
          "The prompt's label in the minibuffer's status line, drawn by the loop (`Loop.promptFace`)." },
      { name := ⟨"minibuffer.candidate"⟩
        meaning :=
          "A row of the candidate list, the minibuffer display's, unless it is the chosen one (`Completion.Displays.candidateFace`)." },
      { name := ⟨"minibuffer.chosen"⟩
        meaning :=
          "The chosen candidate's row of the candidate list, drawn by the minibuffer display (`Completion.Displays.chosenFace`)." },
      { name := ⟨"minibuffer.match"⟩
        meaning :=
          "The ranges of a candidate's text the typed text matched, over its row of the candidate list (`Completion.Displays.matchFace`)." },
      { name := ⟨"minibuffer.annotation"⟩
        meaning :=
          "A candidate's annotation, in its column of the candidate list (`Completion.Displays.annotationFace`)." },
      { name := ⟨"minibuffer.group"⟩
        meaning :=
          "A group's header row in the candidate list (`Completion.Displays.groupFace`)." },
      { name := ⟨"tab-bar"⟩
        meaning :=
          "Each tab's chip in the tab bar, its number and label, drawn by the loop (`TabBar.face`)." },
      { name := ⟨"tab-bar.selected"⟩
        meaning :=
          "The chip of the tab in view in the tab bar, drawn by the loop (`TabBar.selectedFace`)." },
      { name := ⟨"compilation.error"⟩
        meaning :=
          "The location text of an error in a compilation buffer, a span the compile mode sets (`Compile.Severity.face`)." },
      { name := ⟨"compilation.warning"⟩
        meaning :=
          "The location text of a warning in a compilation buffer, a span the compile mode sets (`Compile.Severity.face`)." },
      { name := ⟨"compilation.note"⟩
        meaning :=
          "The location text of a note in a compilation buffer, a span the compile mode sets (`Compile.Severity.face`)." }] ++
    markupEntries ++ syntaxEntries ++
    #[{ name := ⟨"diff.added"⟩
        meaning := "Text a diff adds: drawn by a diff view, declared ahead." },
      { name := ⟨"diff.removed"⟩
        meaning := "Text a diff removes: drawn by a diff view, declared ahead." },
      { name := ⟨"diff.changed"⟩
        meaning := "Text a diff changes: drawn by a diff view, declared ahead." },
      { name := ⟨"gutter"⟩
        meaning :=
          "The gutter beside a view's text, and its line numbers and marks: declared ahead." },
      { name := ⟨"search-match"⟩
        meaning :=
          "A match of the last search in a view's text, drawn by the loop as a decoration (`Loop.searchMatchFace`)." },
      { name := ⟨"review-unexamined"⟩
        meaning :=
          "A tracked excerpt no scene has shown yet, such as a review buffer's hunk never on screen: drawn by the loop over its bytes (`ExcerptView.unexaminedFace`)." },
      { name := ⟨"working-set-drifted"⟩
        meaning :=
          "The quote of a working set's range that was not found in its file, shown as it was stored: a span over the whole of its read-only buffer, drawn in the set's buffer through its excerpt (`packages/working-set/WorkingSet/Run.lean`)." },
      { name := ⟨"block-header"⟩
        meaning :=
          "The header drawn above an excerpt of an excerpt buffer, such as a review buffer's hunk header (`ExcerptView.headerFace`)." }]

/-- The vocabulary's names, in its order. -/
def vocabularyNames : Array FaceName :=
  vocabulary.map (·.name)

/-- The faces a view's cursor is drawn in, in the vocabulary's order: the
entries marked `cursor`. They are `cursor`, the face of a scheme that names
none, and each face a scheme lists as one it draws a cursor in
(`InputScheme.cursorFaces`). The completeness check holds a shipped theme
to every one of them (`Themes.problems`, `Editor/Theme/Check.lean`). -/
def cursorNames : Array FaceName :=
  (vocabulary.filter (·.cursor)).map (·.name)

end Editor.Face
