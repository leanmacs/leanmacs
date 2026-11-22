import Editor.Test.Minibuffer

/-!
# The fake of `minibuffer-api`

The core's test kit's implementation of the minibuffer's commands and its
mode, `Editor.Test.Minibuffer.package` (the core's
`lean/Editor/Test/Minibuffer.lean`): a package named `minibuffer` that
registers a command under every name the interface declares, and the mode
under its mode name, written over the core's prompt API. A names-only fake
could not answer a prompt, and the core's own tests need one that does, so
the fake is the kit's, and there is one implementation to drift, not two:
the Vim table's tests compare its text to the kit's names, this package's
tests run the contract over the kit's implementation, and the package
`minibuffer` runs the same contract. A consumer's tests use it in place of
any implementation, so they import no implementation package.
-/

namespace MinibufferApiTest

/-- The fake: the core's test kit's minibuffer package
(`Editor.Test.Minibuffer.package`). -/
def fake : Editor.Package :=
  Editor.Test.Minibuffer.package

end MinibufferApiTest
