/-!
# The headless fixture harness: a fixture

A headless fixture as the harness knows it (`docs/dev-practices/headless-mode.md`,
"How the gate runs a fixture"): its script, its config directory and its
expected output, each a path from the repository's root, which is the
fixture's identity, and the path helpers the harness's pure modules share.
Pure: it imports nothing, so model-test pins what is built on it.
-/

namespace Editor.Test.Fixture

/-- A headless fixture's parts, as discovery finds them (`Editor/Test/Fixture/Discover.lean`):
paths from the repository's root. -/
structure Parts where
  /-- The script, the fixture's identity: `tests/headless/keys-script`. -/
  script : String
  /-- The config directory the script runs against. -/
  config : String
  /-- The expected output, when there is one: a fixture with none is held
  by its setup's after-checks alone (`Editor/Test/Fixture/Setup.lean`). -/
  expected : Option String
  deriving DecidableEq, Repr

/-- `name` under the directory `directory`, or `name` alone under none. -/
def joinPath (directory name : String) : String :=
  if directory.isEmpty then name else s!"{directory}/{name}"

/-- `path` with a trailing `/` dropped, as a root may be written. -/
def trimmed (path : String) : String :=
  if path.length > 1 && path.endsWith "/" then (path.dropEnd 1).toString else path

/-- `path` as a path from `repository`'s root: its part after
`<repository>/` when it is under it, and otherwise as given. -/
def underRepository (repository path : String) : String :=
  let repository := trimmed repository
  let path := trimmed path
  if path.startsWith (repository ++ "/") then (path.drop (repository.length + 1)).toString else path

/-- Whether `path` is `root` or under it. -/
def isUnder (root path : String) : Bool :=
  let root := trimmed root
  path == root || path.startsWith (root ++ "/")

end Editor.Test.Fixture
