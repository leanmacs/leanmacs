import Editor.Api
import Editor.Package

/-!
# The fixture package `greeting`

A package outside the core, used by tests alone
(`docs/design/packages.md`, "The package set and its build"). It registers
two commands, each of which puts a text in the echo area:

- `greeting-hello` says `helloText`. No other package registers it, so an
  editor built from a set that holds this package runs it, and an editor
  built from a set without it answers that there is no such command.
- `greeting-reply` says `replyText`. The fixture package `greeting-loud`,
  which requires this one, registers the same name with another text, so
  which text an editor shows says which of the two registered later.

It imports the editor API and the package type, and nothing else of the
core.
-/

namespace Greeting

/-- What `greeting-hello` says. -/
def helloText : String :=
  "hello from the greeting package"

/-- What `greeting-reply` says. -/
def replyText : String :=
  "greeting replies"

/-- The name of the command both this package and `greeting-loud`
register. -/
def replyName : String :=
  "greeting-reply"

/-- The package `greeting`: the commands `greeting-hello` and
`greeting-reply`. -/
def package : Editor.Package :=
  { name := "greeting"
    setup := do
      Editor.command "greeting-hello" (Editor.message helloText)
      Editor.command replyName (Editor.message replyText) }

end Greeting
