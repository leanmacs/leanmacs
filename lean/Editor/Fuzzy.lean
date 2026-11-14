import Editor.Program

/-!
# The fuzzy matching interface

What the editor asks of a fuzzy matcher: which of some candidates a pattern
matches, and in what order. It is a port like the others
(`Editor/Program.lean`): a request, a pure model (`Editor/Fuzzy/Model.lean`)
and a contract every implementation is held to
(`Editor/Fuzzy/Contract.lean`).

## The request

- **`rank pattern candidates`** answers the indices of the candidates the
  pattern matches, best first, each once.

It refuses nothing: any pattern and any candidates have an answer, which may
be no index at all.

## What matches

A candidate matches when the pattern's Unicode scalar values all occur in
it, in the pattern's order, adjacent or apart. That is the whole rule:

- **Case is kept.** `a` does not match `A`.
- **A scalar value matches itself alone.** An accented letter is not its
  base letter, and a composed character is not its decomposed form.
- **No character of a pattern is syntax.** A space is a character to find.
- **The empty pattern matches every candidate**, and no other pattern
  matches the empty candidate.

It is this small so that the model and a matching library can agree on every
input and not only on a table of cases: the model needs no table of
Unicode's, since a `String` is a list of scalar values.

## The order

**A candidate that is the pattern comes first.** That is all an asker may
rest on. After the candidates that are the pattern the order is the
implementation's: a matching library's scores, or in the model the order the
candidates came in. So logic above the port is tested on the model, and a
check of it computes what it expects with the model and never writes an
order out.

## Where an addition goes

| Addition | Where |
|---|---|
| Something else asked of the matcher | A constructor of `FuzzyRequest`, its case in `FuzzyRequest.Reply`, an operation here, its case in the model, and a property of the contract |
| A rule of what matches, or of the order, that every implementation keeps | The model and a case of the contract, in one commit with the Rust port's fake and contract (`crates/editor-fuzzy`) |
| A binding to a matching library | A handler of these requests, which runs the contract; nothing here |

Pinned by the contract, which `model-test` runs against the model and
`contract-test` against the real binding (`Editor/Fuzzy/Real.lean`), and by
`ModelTest.fuzzyChecks` for what only the model shows.
-/

namespace Editor

/-- What may be asked of the fuzzy matcher. -/
inductive FuzzyRequest where
  /-- The indices of the `candidates` that `pattern` matches, best first. -/
  | rank (pattern : String) (candidates : Array String)
  deriving DecidableEq, Repr

/-- The type of the reply to each request: for a ranking, the indices of
the candidates that match, best first, each once. -/
def FuzzyRequest.Reply : FuzzyRequest → Type
  | .rank _ _ => Array Nat

/-- The fuzzy port: `FuzzyRequest` and the reply to each request. -/
abbrev fuzzyPort : Port :=
  { Request := FuzzyRequest, Reply := FuzzyRequest.Reply }

/-- A program over the fuzzy port. It has no error: nothing is refused. -/
abbrev FuzzyM :=
  Program fuzzyPort

/-- An answerer of the fuzzy port's requests in `IO`: a binding to a
matching library. -/
abbrev FuzzyHandler :=
  (request : FuzzyRequest) → IO request.Reply

namespace Fuzzy

/-- The indices of the `candidates` that `pattern` matches, best first, each
once: a candidate matches when the pattern's scalar values all occur in it
in order, and a candidate that is the pattern comes first. -/
def rank (pattern : String) (candidates : Array String) : FuzzyM (Array Nat) :=
  Program.request (port := fuzzyPort) (.rank pattern candidates)

end Fuzzy

end Editor
