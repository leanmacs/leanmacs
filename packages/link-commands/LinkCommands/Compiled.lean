import Editor.Package
import LinkCommands

/-!
# The `link-commands` package

What a host registers so that a buffer's links are followed and moved
between from the keyboard (`LinkCommands.lean`): the package
`link-commands` (`LinkCommands.package`, `lean/Editor/Package.lean`), whose
`setup` is the core's `Links.setup`. A host registers it for the owner
`link-commands` when its loop starts, before any config
(`lean/Editor/Config/Packages.lean`). Both of the executable's hosts are
handed it, through the entry module of the Lake package `link-commands`
(`LinkCommands/EditorPackage.lean`).

This module is apart from `LinkCommands.lean` because it is what a host is
handed, not what config calls.

Pinned by `LinkCommandsTest.linkCommandsChecks`.
-/

namespace Editor.LinkCommands

/-- The package `link-commands`: the link commands, the job `url-open` and
the links mode. -/
def package : Package :=
  { name := "link-commands", setup }

end Editor.LinkCommands
