import Editor.Completion
import Editor.Completion.AtPoint

/-!
# Completion sources for tests

Hand-written sources for the checks of what asks a source
(`Editor/Completion.lean`): one that shows what it was asked, and one that
is refused. The model, a source that answers the same candidates whatever
it is asked, is `Source.fixed` itself. `model-test` imports this module;
nothing the editor runs does.

- `Fake.echo name category` answers one candidate, whose text is the
  query's text and whose annotation is the number of the view the query
  is asked from, so a check sees what was asked.
- `Fake.refusing name category` is refused with `TextError.badRange`
  before it answers, so a check sees what a refused source does to the
  command that asked it.
- `Fake.AtPoint.refusing name` is an at-point source
  (`Editor/Completion/AtPoint.lean`) refused the same way, so a check sees
  that an at-point source was not asked.
-/

namespace Editor.Completion.Fake

/-- A source called `name`, of `category`, that answers one candidate: the
query's text, annotated with the number of the query's view. It asks the
port nothing. -/
def echo (name category : String) : Source :=
  { name, category
    candidates := fun query =>
      pure #[{ text := query.text, annotation := some (toString query.view.index) }] }

/-- A source called `name`, of `category`, that is refused with
`badRange` before it answers. -/
def refusing (name category : String) : Source :=
  { name, category, candidates := fun _ => throw .badRange }

/-- An at-point source called `name` that is refused with `badRange`
before it answers: asking it refuses the asking command, so a check sees it
was never asked. -/
def AtPoint.refusing (name : String) : Completion.AtPoint :=
  { name, ask := fun _ => throw .badRange }

end Editor.Completion.Fake
