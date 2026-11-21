import Editor.Completion.Display
import Editor.Completion.Style
import Editor.Package
import Editor.Setup
import Editor.TypedPath

/-!
# Config tests: support: Listings

The package the config tests' hosts are handed for prompts' listings
(`listingsPackage`): styles and a display written for these tests, none of
them the ones that ship, since the core's hosts are handed no package of
the completion feature (`packages/completion/`). Its rules are stated here and are no shipped one's.
Shared by several test modules; it holds no checks of its own.
-/

namespace ConfigTest

open Editor

/-- The style the hosts' prompts are matched with when config chooses none,
`library`: the fuzzy port's ranking (`Fuzzy.rank`), in its order, with no
ranges, the core's own style under a name of its own. It is registered
first, so it is the default. -/
def libraryStyle : Completion.Style :=
  { Completion.Style.unregistered with name := "library" }

/-- A style the hosts are handed, `parts`: it keeps the candidates that hold
every space-separated part of the text as a run of their characters, in
their order, with no ranges. -/
def partsStyle : Completion.Style :=
  .keeping "parts" fun text candidate =>
    (text.splitOn " ").all fun part => part.isEmpty || (candidate.splitOn part).length > 1

/-- The last component of `path`: what follows its last `/`, a trailing `/`
not counted, so `notes/` is `notes`. -/
def lastOf (path : String) : String :=
  (TypedPath.split (if path.endsWith "/" then String.ofList path.toList.dropLast else path)).2

/-- The style the hosts' file prompts are matched with, `path`, the name the
core's files package gives the category `file` (`Completion.Paths.category`)
as text: the fuzzy port's ranking of the text's last component, what follows
its last `/`, against each candidate's (`lastOf`), in its order, with no
ranges. -/
def lastsStyle : Completion.Style :=
  { name := "path"
    hits := fun text candidates => do
      return (← Fuzzy.rank (TypedPath.split text).2 (candidates.map lastOf)).map
          Completion.Hit.ofIndex }

/-- How many rows `rowsDisplay` shows at most. -/
def listedRows : Nat :=
  10

/-- The face `rowsDisplay` draws a candidate's row in, unless it is the
chosen one. -/
def listedRowFace : FaceName :=
  ⟨"test.row"⟩

/-- The face `rowsDisplay` draws the chosen candidate's row in. -/
def listedChosenFace : FaceName :=
  ⟨"test.chosen"⟩

/-- The display the hosts' listings are shown with, `rows`: a row for each of
at most `listedRows` candidates, from where its window starts, which is
where it last did, earlier at the chosen candidate when that is above it,
and so that the chosen one is the last row when it is past them; each row
the candidate's label, or its text when it has none, then two spaces and
its annotation when it has one, the whole row in `listedRowFace`, or
`listedChosenFace` for the chosen one. No group header, no column. -/
def rowsDisplay : Completion.Display :=
  { name := "rows"
    sheet := fun showing =>
      let size := showing.listed.size
      let start := if size == 0 then 0 else min showing.first (size - 1)
      let first :=
        match showing.chosen with
        | some chosen =>
          if chosen < start then chosen
          else if start + listedRows ≤ chosen then chosen + 1 - listedRows else start
        | none => start
      { first
        rows :=
          (showing.listed.extract first (first + listedRows)).mapIdx fun index listed =>
            let shown := listed.candidate.label.getD listed.text
            let text :=
              Completion.oneLine
                (match listed.candidate.annotation with
                | some annotation => s!"{shown}  {annotation}"
                | none => shown)
            let face :=
              if showing.chosen == some (first + index) then listedChosenFace else listedRowFace
            { text
              decorations :=
                if text.isEmpty then #[]
                else #[{ start := 0, stop := text.utf8ByteSize, face }] } } }

/-- The package `listings`, which the config tests' hosts are handed before
any other of theirs: the styles `library`, the default, `parts` and `path`,
and the display `rows`, the default. -/
def listingsPackage : Package :=
  { name := "listings"
    setup := do
      defineStyle libraryStyle
      defineStyle partsStyle
      defineStyle lastsStyle
      defineDisplay rowsDisplay }

end ConfigTest
