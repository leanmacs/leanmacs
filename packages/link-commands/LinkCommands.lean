import Editor.Links

/-!
# The link commands

The package `link-commands`'s `setup`: the core's `Links.setup`
(`lean/Editor/Links.lean`), which registers `link-follow`, `link-next` and
`link-previous`, the job `url-open` and the links mode, under the names the
core declares. The core holds every decision; this package is where they
are registered, so leaving it out leaves link following out: a buffer's
links are still drawn in the link face, and a mode keeps its own
`activate`.

Config reaches the names and the reference resolver's extension point
(`Links.Resolver`) through this package's entry module, which brings
`Editor.Links` into the set's config base.

Pinned by `LinkCommandsTest.linkCommandsChecks`.
-/

namespace Editor.LinkCommands

/-- The package's `setup`: the core's `Links.setup`. -/
def setup : SetupM Unit :=
  Links.setup

end Editor.LinkCommands
