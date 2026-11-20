-- Quoted whole in docs/packages/writing-a-package.md: change the guide with it.
import WordCount

/-!
# The entry module of the Lake package `word-count`

The package-set build imports this module and registers `packages`, after
the packages of every Lake package this one requires.
-/

namespace WordCount.EditorPackage

/-- The packages of the Lake package `word-count`, in the order a host
registers them. -/
def packages : Array Editor.Package :=
  #[WordCount.package]

end WordCount.EditorPackage
