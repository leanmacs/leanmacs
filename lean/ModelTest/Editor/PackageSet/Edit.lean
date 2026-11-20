import Editor.PackageSet.Edit
import ModelTest.Check

/-!
# Model tests: `Editor/PackageSet/Edit.lean`

The model tests of `Editor/PackageSet/Edit.lean`: `packageSetEditChecks`,
on exact texts. The root module `ModelTest` runs them; its module doc says
what each shows.
-/

namespace ModelTest

open Editor
open Editor.PackageSet

namespace EditTest

/-- The lakefile the editor generates for the default set at `/w/packages`,
with a user's package. -/
def lakefile : String :=
  "name = \"config\"\n\n[[require]]\nname = \"default-set\"\npath = \"/w/packages\"\n\n# My own package.\n[[require]]\nname = \"hello\"\npath = \"../hello\"\n\n[[lean_lib]]\nname = \"Config\"\nglobs = [\"Config.+\"]\n"

/-- Its requires, as Lake reads them. -/
def required : Array Require :=
  #[{ name := "default-set", source := .path "/w/packages" },
    { name := "hello", source := .path "../hello" }]

/-- The default set's own requires. -/
def setRequired : Array Require :=
  #[{ name := "editor-core", source := .path "../lean" },
    { name := "shipped-themes", source := .path "shipped-themes" },
    { name := "compile", source := .path "compile" }]

/-- Two answers of an edit are equal when both are the same text or the
same refusal. -/
instance : BEq (Except String String) where
  beq
    | .ok one, .ok other => one == other
    | .error one, .error other => one == other
    | _, _ => false

end EditTest

open EditTest in
/-- The checks of the edits of a config's `lakefile.toml`
(`Editor/PackageSet/Edit.lean`), on exact texts: where each table is;
install of a path, a git and a Reservoir require; remove; the default set
expanded without one of its packages; a rev set; and each refusal. -/
def packageSetEditChecks : List Check :=
  [{  name := "a table runs from its header to its last line that is not blank or a comment"
      run := pure (tables (linesOf lakefile) == #[(2, 5), (7, 10)]) },
    { name := "install adds a path, a git or a Reservoir table after the last require"
      run :=
        pure
          (install lakefile required { name := "x", source := .path "/p/x" } ==
              .ok
                "name = \"config\"\n\n[[require]]\nname = \"default-set\"\npath = \"/w/packages\"\n\n# My own package.\n[[require]]\nname = \"hello\"\npath = \"../hello\"\n\n[[require]]\nname = \"x\"\npath = \"/p/x\"\n\n[[lean_lib]]\nname = \"Config\"\nglobs = [\"Config.+\"]\n" &&
            install "name = \"c\"\n" #[]
                { name := "g", source := .git "https://h/g" (some "v1") none } ==
              .ok
                "name = \"c\"\n\n[[require]]\nname = \"g\"\ngit = \"https://h/g\"\nrev = \"v1\"\n" &&
            install "name = \"c\"" #[] { name := "b", source := .reservoir "lc" none } ==
              .ok "name = \"c\"\n\n[[require]]\nname = \"b\"\nscope = \"lc\"\n") },
    { name := "install refuses a name the lakefile already requires"
      run :=
        pure
          (install lakefile required { name := "hello", source := .path "/x" } ==
            .error "the lakefile already requires hello") },
    { name := "remove takes a require's table out with one blank line after it"
      run :=
        pure
          (remove lakefile required "hello" "/c" (some "default-set") setRequired ==
            .ok
              "name = \"config\"\n\n[[require]]\nname = \"default-set\"\npath = \"/w/packages\"\n\n# My own package.\n[[lean_lib]]\nname = \"Config\"\nglobs = [\"Config.+\"]\n") },
    { name :=
        "removing a default package expands the default set into its own requires but that one, each path made absolute against the set's directory"
      run :=
        pure
          (remove lakefile required "compile" "/c" (some "default-set") setRequired ==
            .ok
              "name = \"config\"\n\n[[require]]\nname = \"editor-core\"\npath = \"/w/lean\"\n\n[[require]]\nname = \"shipped-themes\"\npath = \"/w/packages/shipped-themes\"\n\n# My own package.\n[[require]]\nname = \"hello\"\npath = \"../hello\"\n\n[[lean_lib]]\nname = \"Config\"\nglobs = [\"Config.+\"]\n") },
    { name :=
        "remove refuses the core, a package neither the lakefile nor the shipped set requires, and a lakefile whose requires are no tables"
      run :=
        pure
          (remove lakefile required "editor-core" "/c" (some "default-set") setRequired ==
              .error "the core cannot be removed" &&
            remove lakefile required "nope" "/c" (some "default-set") setRequired ==
              .error "the lakefile does not require nope, and neither does default-set" &&
            remove lakefile required "compile" "/c" none setRequired ==
              .error "the lakefile does not require compile" &&
            remove "require = [{ name = \"a\", path = \"a\" }]\n"
                #[{ name := "a", source := .path "a" }] "a" "/c" none #[] ==
              .error "its requires are not each a [[require]] table, so edit it by hand") },
    { name :=
        "set a rev replaces a git require's rev, or adds one after its git line; a path require has none"
      run :=
        let git := "[[require]]\nname = \"g\"\ngit = \"https://h/g\"\nrev = \"v1\"\n"
        let bare := "[[require]]\nname = \"g\"\ngit = \"https://h/g\"\nsubDir = \"s\"\n"
        let gits : Array Require :=
          #[{ name := "g", source := .git "https://h/g" (some "v1") none }]
        pure
          (setRev git gits "g" "abc" ==
              .ok "[[require]]\nname = \"g\"\ngit = \"https://h/g\"\nrev = \"abc\"\n" &&
            setRev bare gits "g" "v2" ==
              .ok
                "[[require]]\nname = \"g\"\ngit = \"https://h/g\"\nrev = \"v2\"\nsubDir = \"s\"\n" &&
            setRev lakefile required "hello" "v2" ==
              .error "hello is not a git dependency, so it has no rev" &&
            setRev lakefile required "nope" "v2" == .error "the lakefile does not require nope") }]

end ModelTest
