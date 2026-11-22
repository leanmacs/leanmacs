import Editor.Completion.Candidate

/-!
# Completion displays

What draws a listing of candidates: a display. It is an interface like the
editor's ports, with a pure model (`Display.plain`), the core's own display
(`Display.unregistered`), the displays that ship, which the `completion`
package registers (`packages/completion/Completion/Displays.lean`), and a contract every
display is held to (`Editor/Completion/DisplayContract.lean`). The loop asks the prompt's
display at each publish (`EditorState.displayed`, `Editor/State.lean`;
`Loop.candidateListView`, `Editor/Loop.lean`), chosen by the prompt's
category (`Displaying`).

## A display

- **A name**, which config registers it under and chooses it by
  (`defineDisplay`, `useDisplay`, `useDisplayFor`, `Editor/Setup.lean`).
- **A function from what it is shown to a sheet** (`Showing`, `Sheet`):
  the whole listing, each candidate with the ranges of its text that
  matched, the choice, where its window started in the last scene and
  whether the listing holds two groups or more; it answers its rows, top
  to bottom, each a text with spans of it in faces, and where its window
  starts now.

It is a pure Lean function, as a style is a program over the fuzzy port
alone: it reads no state and asks no port, so it cannot be refused or
interrupted, and the loop may run config's display inside the publish, as
it runs config's mode-line segments. Neither the prompt nor the minibuffer
appears in what it is shown, so a session at point can hand its own
candidates to the same interface. A listing need not be a prompt's or a
session's, nor have typed text: the key hints are a listing with nothing
chosen and no typed text, of the category `key`, shown by the display
chosen for `key` (`Editor/Completion/Keys.lean`, `EditorState.displayed`).

Nothing in it is a program the state holds: the state keeps the sheet the
last publish answered (data) and where its window started, never a
display. The host builds `Displaying` from the registry at every step
(`Config.Registry.displaying`), so a reload changes it from the next
scene.

## Choosing one

`Displaying` is what the loop is handed (`Loop.Keys.displaying`): a default
display and, for a category, the display config chose for it.
`displayFor` answers a category's display, or the default for a category
with none and for a prompt with no category.

With no choice made, the default display is the one **registered first**,
by the rule of styles (`Editor/Completion/Style.lean`, "Choosing one"): in
the default set `minibuffer`, the `completion` package's. With no display
registered at all the core uses its own, `Display.unregistered`: the
interface's model, `Display.plain "plain"`, registered by no package and
answered as the owner `compiled`'s (`Config.Registry.displayEntry`). A host
that is told of no registry hands `Displaying.unregistered`. A name no
display is registered under is said in the install report
(`Display.unknown`).

## Where an addition goes

| Addition | Where |
|---|---|
| Something more a display is handed | A field of `Showing` |
| Something more a row says | A field of `Row` |
| A new display that ships | A value in the `completion` package (`packages/completion/Completion/Displays.lean`), in `Displays.shipped`, and run by `CompletionTest.minibufferDisplayChecks` |
| A rule every display keeps | A property of `Editor/Completion/DisplayContract.lean` |
| A placement other than the minibuffer's place | A later phase's (`rdm:task/completion-float-displays`) |

Pinned by `ModelTest.displayContractChecks` (the contract, on the model and
the core's own display) and `completionDisplayChecks` (the model and the
choice). The shipped display is pinned by `CompletionTest.minibufferDisplayChecks`.
-/

namespace Editor.Completion

/-- What a display is handed: the listing and the choice, and where its
window started last. -/
structure Showing where
  /-- The whole listing, in order, each with its ranges. -/
  listed : Array Listed := #[]
  /-- The choice: an index of `listed`, or none. -/
  chosen : Option Nat := none
  /-- The index the window started at in the last scene. -/
  first : Nat := 0
  /-- Whether the listing holds two groups or more, computed when it was
  made (`grouped`). -/
  grouped : Bool := false
  /-- The category of what is listed, or none. -/
  category : Option String := none
  deriving DecidableEq, Repr

/-- One row a display shows: its text, with no line feed, and spans of it
in faces, row-relative, a later one drawn over an earlier one. -/
structure Row where
  /-- What it says. -/
  text : String
  /-- Spans of `text` in faces, as byte offsets of the row. -/
  decorations : Array Decoration := #[]
  deriving DecidableEq, Repr

/-- What a display answers: its rows, top to bottom, and where its window
starts now. -/
structure Sheet where
  /-- The rows, top to bottom. -/
  rows : Array Row := #[]
  /-- The index of the listing the window starts at. -/
  first : Nat := 0
  deriving DecidableEq, Repr

/-- What draws a listing of candidates. -/
structure Display where
  /-- The name it is registered and chosen under. -/
  name : String
  /-- What it shows of `showing`. -/
  sheet : Showing → Sheet

/-- The displays a host hands the loop: a default, and one per category
when chosen. -/
structure Displaying where
  /-- The display of a prompt whose category has none chosen, and of one
  with no category. -/
  default : Display
  /-- The display of a category; `none` for one that falls to the
  default. -/
  byCategory : String → Option Display := fun _ => none

/-- The display a listing of `category` is shown with: the one chosen for
it, else the default. -/
def Displaying.displayFor (displaying : Displaying) (category : Option String) : Display :=
  (category.bind displaying.byCategory).getD displaying.default

/-- `text` with each line feed replaced by a space: the same bytes, one
line. -/
def oneLine (text : String) : String :=
  text.map fun char => if char == '\n' then ' ' else char

/-- The text of a sheet, as a view shows it: its rows joined by line feeds,
each line feed in a row replaced by a space, which keeps its byte count. -/
def Sheet.text (sheet : Sheet) : String :=
  "\n".intercalate (sheet.rows.toList.map (oneLine ·.text))

/-- The decorations of a sheet over its text (`Sheet.text`): each row's,
offset by the bytes of the rows before it and their line feeds. -/
def Sheet.decorations (sheet : Sheet) : Array Decoration :=
  (sheet.rows.foldl
      (fun (all, offset) row =>
        (all ++
            row.decorations.map fun decoration =>
              { decoration with
                start := decoration.start + offset, stop := decoration.stop + offset },
          offset + row.text.utf8ByteSize + 1))
      (#[], 0)).1

/-- Whether `listed` holds two groups or more: two of its candidates'
groups differ. It stops at the first difference. -/
def grouped (listed : Array Listed) : Bool :=
  match listed[0]? with
  | some first => listed.any (·.candidate.group != first.candidate.group)
  | none => false

/-- The model of a display: one called `name` that shows every listed
candidate's text one a row, `"> "` before the chosen one and `"  "` before
the rest, with no faces, its window always at 0. The fake display of the
tests. -/
def Display.plain (name : String) : Display :=
  { name
    sheet := fun showing =>
      {
        rows :=
          showing.listed.mapIdx fun index listed =>
            {
              text :=
                (if showing.chosen == some index then "> " else "  ") ++ oneLine listed.text } } }

/-- The core's own display, for a registry where no display is registered:
the interface's own model, `Display.plain "plain"`. It is registered by no
package; the registry answers it as the owner `compiled`'s
(`Config.Registry.displayEntry`). -/
def Display.unregistered : Display :=
  Display.plain "plain"

/-- What the report says of a display chosen under `name` that no display
is registered under. -/
def Display.unknown (name : String) : String :=
  s!"no completion display is registered under `{name}`"

/-- The displaying a host hands when it is told of no display: the core's
own display (`Display.unregistered`) for every listing. -/
def Displaying.unregistered : Displaying :=
  { default := Display.unregistered }

end Editor.Completion
