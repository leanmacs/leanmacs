import Editor.Floating
import Editor.Layout

/-!
# Display rules

Where a buffer a command shows goes, as config data: a list of rules,
matched in order on the buffer (its modes and its name) and on what opened
it (the name of the command that asked), each naming a target. The module
is pure: the editor state decides with it (`EditorState.displaying`,
`Editor/State.lean`), and a command asks through the editor API
(`BufferId.display`, `Editor/Api.lean`).

- **A rule** (`DisplayRule`) sets any of a mode, a name and an opener, and
  matches a buffer when every field it sets holds (`DisplayRule.matches`):
  a mode is the buffer's major mode or any of its minor modes, a name is the
  buffer's exactly, and an opener is the asking command's name. A rule that
  sets none matches every buffer.
- **The first rule that matches is chosen**, and with none the fallback is
  (`DisplayRule.fallback`): a new window in the stack, focused. So a buffer
  that is not the one being edited never replaces main's, and main is never
  split.
- **A caller may give the fallback's focus** (`choose`'s `focus`, which
  `BufferId.display` passes on): the compilation buffer is displayed with
  `false`, so with no rule that matches it opens in the stack and the focus
  stays where compile was asked from. It is only the fallback's: a rule
  that matches keeps its own `focus` (decided 2026-11-17).
- **The targets** (`DisplayTarget`): the window the asking command acts on,
  main, a new window at the end of the tiled list, a new window docked at
  an edge, a new float centred in the frame and a new tab. A rule's
  `focus` says whether the window the buffer is shown in is focused.
- **A float target** (`DisplayTarget.float`) opens a float anchored to the
  frame, centred in the tiled area (`Editor/Floating.lean`), of the rule's
  share, 60 by 50 percent unless it says another, and transient unless it
  says `pinned`. Config writes `.float`, `.float { width := 80, height :=
  70 }` or `.float (pinned := true)`. With the rule's `focus` true by
  default, the buffer opens focused in a popup that goes away when the
  focus leaves it. A window that shows the buffer already, a float among
  them, is still used first.
- **A target the layout lacks is missing** (`DisplayTarget.missing?`):
  tabs, which are not built yet, and an edge the layout config chose has
  none at. Config's rules are checked against it at install, and a rule
  whose target is missing is left out and said
  (`Editor/Config/Reload.lean`).

The name avoids `Editor.Display`, the display port.

Pinned by `ModelTest.displayRuleChecks`.
-/

namespace Editor

/-- Where a display rule sends a buffer. -/
inductive DisplayTarget where
  /-- The window the asking command acts on: for the minibuffer's view, the
  window its prompt was asked from (`EditorState.shownIn`). -/
  | focused
  /-- The first window of the tiled list, which shows it in place of its
  buffer. -/
  | main
  /-- A new window at the end of the tiled list. -/
  | stack
  /-- A new window docked at the edge at `side`. -/
  | edge (side : Side)
  /-- A new floating window, anchored to the frame and centred in the tiled
  area, of `share`, transient unless `pinned` (`Editor/Floating.lean`). -/
  | float (share : Floating.Share := {}) (pinned : Bool := false)
  /-- A window in a new tab: not built yet. -/
  | newTab
  deriving DecidableEq, Repr

/-- A display rule: what it matches, where it sends a buffer, and whether
that window is focused. -/
structure DisplayRule where
  /-- The buffer's major mode or one of its minor modes, if set. -/
  mode : Option String := none
  /-- The buffer's name, exactly, if set. -/
  name : Option String := none
  /-- The name of the command that asked for it to be shown, if set. -/
  opener : Option String := none
  /-- Where the buffer goes. -/
  target : DisplayTarget
  /-- Whether the window it is shown in is focused. -/
  focus : Bool := true
  deriving DecidableEq, Repr

/-- What a rule is matched on. -/
structure DisplayRule.Facts where
  /-- The buffer's name. -/
  name : String
  /-- The buffer's modes: its major mode first, then its minor modes. -/
  modes : List String
  /-- The name of the command that asked for the buffer to be shown. -/
  opener : String
  deriving DecidableEq, Repr

/-- Whether `rule` matches `facts`: every field it sets holds. It is named
in full, outside the namespace, because `matches` alone is a keyword. -/
def DisplayRule.matches (rule : DisplayRule) (facts : DisplayRule.Facts) : Bool :=
  rule.mode.all facts.modes.contains && rule.name.all (· == facts.name) &&
    rule.opener.all (· == facts.opener)

namespace DisplayRule

/-- The rule a buffer no rule matches is shown by: a new window in the
stack, focused. -/
def fallback : DisplayRule :=
  { target := .stack }

/-- The first of `rules` that matches `facts`, and `fallback` with `focus`
as its focus when none does: the caller's default, which a rule that
matches does not take. -/
def choose (rules : Array DisplayRule) (facts : Facts) (focus : Bool := true) : DisplayRule :=
  (rules.find? (·.matches facts)).getD { fallback with focus }

end DisplayRule

namespace DisplayTarget

/-- What is said of a new-tab target: there are none to send a buffer
to. -/
def noTabs : String :=
  "there are no tabs yet"

/-- Why `target` does not exist under `layout`, if it does not: tabs are not
built yet, and an edge the layout has none at (`Layout.edgeSides`) is
missing. The focused window, main, the stack and a float always exist. -/
def missing? (target : DisplayTarget) (layout : Layout) : Option String :=
  match target with
  | .newTab => some noTabs
  | .edge side => if layout.edgeSides.contains side then none else some (Layout.noEdge side)
  | .focused | .main | .stack | .float .. => none

end DisplayTarget

end Editor
