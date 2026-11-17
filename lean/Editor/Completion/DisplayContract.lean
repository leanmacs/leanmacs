import Editor.Completion.Display

/-!
# The contract of completion displays

What every completion display (`Editor/Completion/Display.lean`) answers, as
one list of properties. `model-test` runs it against the model,
`Display.plain`, and against the shipped minibuffer display at 0, 1, 3 and
10 rows (`ModelTest.displayContractChecks`). A display is a pure function,
so there is no real implementation behind a port to run it against: the
model and every shipped display are checked by the same properties. This
module imports only the interface, so the contract never depends on a
display.

## What it asks

Each property runs over a table of what a display is shown (`showings`):
listings of 0, 1, 4, 15 and 30 candidates, of texts with a character of
two bytes among them, some with a label, some with an annotation, in two
groups, with nothing chosen and with the first, a middle and the last
chosen, and with the window last started at 0, the middle, the last and
past the end.

- **The decorations** (`decorations`): each decoration of a row is not
  empty and lies within the row's text, both ends on character boundaries.
- **The rows** (`lineFeeds`): no row holds a line feed.
- **The empty listing** (`empty`): it answers no rows, its window at 0.
- **The window** (`window`): a listing that is not empty answers a window
  that starts at one of its indices.

It does not ask what a row says, nor how many rows there are: that is each
display's own rule, pinned on the display.

## Where an addition goes

| Addition | Where |
|---|---|
| A rule every display keeps | A `Property` in `properties`, with its name a definition here |
| A case it is asked over | A `Showing` of `showings` |
-/

namespace Editor.Completion.DisplayContract

/-- One property of completion displays. -/
structure Property where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Whether it holds of `display`. -/
  holds : Display → Bool

/-- The texts the table's candidates cycle through: `é` is two bytes. -/
def texts : Array String :=
  #["w", "édit", "wq", "rewrite", "xé"]

/-- The `index`th candidate of the table: a text of `texts`, a label on
every third, an annotation on every other, in group `a` for the first half
of `count` and `b` for the rest, and its first character's bytes matched. -/
def listedAt (count index : Nat) : Listed :=
  let text := (texts[index % texts.size]?).getD "w"
  let first := (text.toList.head?.map Char.utf8Size).getD 0
  { candidate :=
      { text
        label := if index % 3 == 2 then some s!"label {index}" else none
        annotation := if index % 2 == 1 then some s!"note é{index}" else none
        group := some (if 2 * index < count then "a" else "b") }
    ranges := if first == 0 then #[] else #[⟨0, first⟩] }

/-- The listing of `count` of the table's candidates. -/
def listingOf (count : Nat) : Array Listed :=
  (Array.range count).map (listedAt count)

/-- What a display is asked with: every listing of 0, 1, 4, 15 and 30
candidates, with nothing chosen and with the first, a middle and the last
chosen, and the window last started at 0, the middle, the last and past the
end. -/
def showings : List Showing :=
  [0, 1, 4, 15, 30].flatMap fun count =>
    let listed := listingOf count
    let choices := [none, some 0, some (count / 2), some (count - 1)].filter (·.all (· < count))
    choices.flatMap fun chosen =>
      [0, count / 2, count - 1, count + 3].map fun first =>
        { listed, chosen, first, grouped := grouped listed }

/-- The byte offsets of the character boundaries of `text`: 0, then the
end of each character. -/
def boundaries (text : String) : Array Nat :=
  (text.toList.foldl
      (fun (offsets, offset) char =>
        (offsets.push (offset + char.utf8Size), offset + char.utf8Size))
      (#[0], 0)).1

/-- The name of the property of the decorations. -/
def decorations : String :=
  "each decoration of a row is not empty and lies within the row's text, both ends on character boundaries"

/-- The name of the property of the rows. -/
def lineFeeds : String :=
  "no row holds a line feed"

/-- The name of the property of the empty listing. -/
def empty : String :=
  "an empty listing answers no rows and its window at 0"

/-- The name of the property of the window. -/
def window : String :=
  "a listing that is not empty answers a window that starts at one of its indices"

/-- Whether `holds` holds of the sheet `display` answers for each showing of
`showings`, handed the showing too. -/
def overTable (display : Display) (holds : Showing → Sheet → Bool) : Bool :=
  showings.all fun showing => holds showing (display.sheet showing)

/-- The properties every display keeps. -/
def properties : List Property :=
  [{ name := decorations
     holds := fun display =>
       overTable display fun _ sheet =>
         sheet.rows.all fun row =>
           let bounds := boundaries row.text
           row.decorations.all fun decoration =>
             decoration.start < decoration.stop && bounds.contains decoration.start &&
               bounds.contains decoration.stop },
    { name := lineFeeds
      holds := fun display =>
        overTable display fun _ sheet => sheet.rows.all fun row => !row.text.contains '\n' },
    { name := empty
      holds := fun display =>
        overTable display fun showing sheet =>
          !showing.listed.isEmpty || (sheet.rows.isEmpty && sheet.first == 0) },
    { name := window
      holds := fun display =>
        overTable display fun showing sheet =>
          showing.listed.isEmpty || sheet.first < showing.listed.size }]

/-- The names of `properties` that do not hold of `display`. -/
def failures (display : Display) (properties : List Property := properties) : List String :=
  properties.filterMap fun property => if property.holds display then none else some property.name

end Editor.Completion.DisplayContract
