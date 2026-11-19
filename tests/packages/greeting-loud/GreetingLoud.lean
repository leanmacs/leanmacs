import Editor.Api
import Editor.Package
import Greeting

/-!
# The fixture package `greeting-loud`

A package outside the core that requires another, used by tests alone
(`docs/design/packages.md`, "The package set and its build"). It registers
`greeting-reply`, the name the fixture package `greeting` registers
(`Greeting.replyName`), with a text of its own. Of two packages that
register one name the later is the one found, and a package registers after
every package it requires, so an editor built from a set that holds both
says `replyText` here, never `greeting`'s.
-/

namespace GreetingLoud

/-- What this package's `greeting-reply` says: `greeting`'s reply, in
capitals. -/
def replyText : String :=
  Greeting.replyText.toUpper ++ ", LOUDLY"

/-- The package `greeting-loud`: `greeting-reply`, under the name
`greeting` registers it with. -/
def package : Editor.Package :=
  { name := "greeting-loud", setup := Editor.command Greeting.replyName (Editor.message replyText) }

end GreetingLoud
