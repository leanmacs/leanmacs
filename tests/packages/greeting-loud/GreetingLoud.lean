import Editor.Api
import Editor.Package
import GreetingApi

/-!
# The fixture package `greeting-loud`

A package outside the core that requires another, used by tests alone
(`docs/design/packages.md`, "The package set and its build"). It registers
`greeting-reply`, the name the fixture package `greeting` registers, with a
text of its own. Of two packages that register one name the later is the
one found, and a package registers after every package it requires, so an
editor built from a set that holds both says `replyText` here, never
`greeting`'s.

It names the command by the constant the interface package `greeting-api`
declares (`GreetingApi.replyName`), never by its text, and imports nothing
of `greeting`, an implementation package
(`docs/design/extension-points.md`, "Reaches by name").
-/

namespace GreetingLoud

/-- What this package's `greeting-reply` says. -/
def replyText : String :=
  "GREETING REPLIES, LOUDLY"

/-- The package `greeting-loud`: `greeting-reply`, under the name
`greeting-api` declares. -/
def package : Editor.Package :=
  { name := "greeting-loud"
    setup := Editor.command GreetingApi.replyName (Editor.message replyText) }

end GreetingLoud
