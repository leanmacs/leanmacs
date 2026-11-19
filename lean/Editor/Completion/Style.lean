import Editor.Completion.Candidate
import Editor.Config.Owner
import Editor.Fuzzy

/-!
# Completion styles

Which of a prompt's candidates the text typed so far matches, and in what
order: a style. It is an interface like the editor's ports, with a pure
model (`Style.keeping`), the styles that ship (`Editor/Completion/Styles.lean`)
and a contract every style is held to (`Editor/Completion/StyleContract.lean`).
The loop asks the prompt's style before each scene (`Loop.listed`,
`Editor/Loop.lean`), chosen by the prompt's category (`Matching`).

## A style

- **A name**, which config registers it under and chooses it by
  (`defineStyle`, `useStyle`, `useStyleFor`, `Editor/Setup.lean`).
- **A function from the typed text and the candidates' texts to hits**
  (`Hit`, `Editor/Completion/Candidate.lean`): the candidates that match,
  in order, each with the ranges of its text that matched, as UTF-8 byte
  offsets.

It is a program over the **fuzzy port** (`Editor/Fuzzy.lean`), not the
editor's: it may ask the matcher and nothing else. So it cannot read the
editor state, cannot be refused (the fuzzy port has no error) and cannot be
interrupted. That is why the loop may run config's style inside the
publish, as it runs config's mode-line segments, without the questions of
refusal and interruption a source raises; and why it runs on a pool thread,
in a match job, against the real matcher alone, for a list longer than the
inline limit (`Loop.inlineMatches`, `Editor/Loop.lean`, "Prompts"). There
it cannot outlive its config: the match job is spawned under the owner of
the style (`Matching.ownerFor`), so an install that cancels config's jobs
cancels a match of config's style.

## Choosing one

`Matching` is what the loop is handed (`Loop.Keys.matching`): a default
style and, for a category, the style config chose for it. `styleFor`
answers a category's style, or the default for a category with none and for
a prompt with no category. The host builds it from the registry for each
step (`Config.Registry.matching`), so a reload changes it from the next
listing; the state holds the prompt's category and never a style. It also
says who registered the style a category gets (`ownerFor`).

## Where an addition goes

| Addition | Where |
|---|---|
| A new style | A value beside its rule (`Editor/Completion/Styles.lean`), registered compiled in `Styles.shipped`, and run by `ModelTest.styleContractChecks` |
| A rule every style keeps | A property of `Editor/Completion/StyleContract.lean` |
| Something more a style answers of a candidate | A field of `Hit` (`Editor/Completion/Candidate.lean`), carried on `Listed`, and what draws it is the display's (`Editor/Completion/Display.lean`) |

Pinned by `ModelTest.styleChecks` (the model, the shipped styles and the
choice) and `styleContractChecks` (the contract, on the model and the
shipped styles), and against the real matcher by `ContractTest.styleFailures`.
-/

namespace Editor.Completion

/-- Which candidates a typed text matches, in what order, and the ranges of
each that matched. -/
structure Style where
  /-- The name it is registered and chosen under. -/
  name : String
  /-- The candidates of `candidates` (their texts) that `text` matches, in
  order, each with the ranges of its text that matched. -/
  hits : (text : String) → (candidates : Array String) → FuzzyM (Array Hit)

/-- The model of a style: one called `name` that matches the candidates
`keep text candidate` holds of, in their order, with no ranges, and asks the
matcher nothing. -/
def Style.keeping (name : String) (keep : String → String → Bool) : Style :=
  { name
    hits := fun text candidates =>
      pure <|
        (Array.range candidates.size).filterMap fun index =>
          if (candidates[index]?).any (keep text) then some (Hit.ofIndex index) else none }

/-- The styles a prompt is matched with: a default, and the style chosen
for a category, when one is. -/
structure Matching where
  /-- The style of a prompt whose category has none chosen, and of one with
  no category. -/
  default : Style
  /-- The style of a category; `none` for one that falls to the default. -/
  byCategory : String → Option Style := fun _ => none
  /-- Who registered the style `styleFor` answers for a prompt's category:
  a match job that runs it is that owner's, so an install that removes
  config's jobs ends a match of config's style (`Editor/Loop.lean`,
  "Prompts"). The owner `compiled`, the core's own, for every category
  unless the host says. -/
  ownerFor : Option String → Config.Owner := fun _ => .compiled

/-- The style a prompt of `category` is matched with: the one chosen for
it, else the default. -/
def Matching.styleFor (matching : Matching) (category : Option String) : Style :=
  (category.bind matching.byCategory).getD matching.default

end Editor.Completion
