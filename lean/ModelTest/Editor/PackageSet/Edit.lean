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

/-- The running editor's core directory. -/
def core : String :=
  "/w/lean"

/-- The core's table, as every edit writes it at the root, its last
require. -/
def coreTable : String :=
  "[[require]]\nname = \"editor-core\"\npath = \"/w/lean\"\n\n"

/-- The text of `lakefile` from its first table on. -/
def tables_ : String :=
  "[[require]]\nname = \"default-set\"\npath = \"/w/packages\"\n\n# My own package.\n[[require]]\nname = \"hello\"\npath = \"../hello\"\n\n"

/-- The text of `lakefile` after its last require. -/
def library : String :=
  "[[lean_lib]]\nname = \"Config\"\nglobs = [\"Config.+\"]\n"

/-- `lakefile` with the core's table at its root, its last require, as the
edits repair it. -/
def repaired : String :=
  "name = \"config\"\n\n" ++ tables_ ++ coreTable ++ library

/-- Its requires, the core last. -/
def repairedRequired : Array Require :=
  required.push { name := "editor-core", source := .path core }

/-- Two answers of `withCore` are equal when both are the same text and
requires, or the same refusal. -/
instance : BEq (Except String (String × Array Require)) where
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
        "removing a default package expands the default set into its own requires but that one and the core, each path made absolute against the set's directory"
      run :=
        pure
          (remove lakefile required "compile" "/c" (some "default-set") setRequired ==
            .ok
              "name = \"config\"\n\n[[require]]\nname = \"shipped-themes\"\npath = \"/w/packages/shipped-themes\"\n\n# My own package.\n[[require]]\nname = \"hello\"\npath = \"../hello\"\n\n[[lean_lib]]\nname = \"Config\"\nglobs = [\"Config.+\"]\n") },
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
            setRev lakefile required "nope" "v2" == .error "the lakefile does not require nope") },
    { name :=
        "withCore writes the core's require by the running core's directory at the root, as its last require, after the set, of a lakefile that requires the set alone"
      run := pure (withCore "/c" lakefile required core == .ok (repaired, repairedRequired)) },
    { name :=
        "withCore takes out an editor-core table that names the core from git, or another directory, wherever it is, and writes the running core's last"
      run :=
        let git :=
          "name = \"config\"\n\n[[require]]\nname = \"default-set\"\npath = \"/w/packages\"\n\n[[require]]\nname = \"editor-core\"\ngit = \"https://h/leanmacs\"\nrev = \"nightly-1\"\nsubDir = \"lean\"\n\n# My own package.\n[[require]]\nname = \"hello\"\npath = \"../hello\"\n\n" ++
            library
        let gitRequired : Array Require :=
          #[required[0]!,
            { name := "editor-core",
              source := .git "https://h/leanmacs" (some "nightly-1") (some "lean") },
            required[1]!]
        let first := "name = \"config\"\n\n" ++ coreTable ++ tables_ ++ library
        let firstRequired : Array Require :=
          #[{ name := "editor-core", source := .path core }] ++ required
        let other :=
          "name = \"config\"\n\n" ++ tables_ ++
            "[[require]]\nname = \"editor-core\"\npath = \"/elsewhere/lean\"\n\n" ++
            library
        let otherRequired : Array Require :=
          required.push { name := "editor-core", source := .path "/elsewhere/lean" }
        pure
          (withCore "/c" git gitRequired core == .ok (repaired, repairedRequired) &&
            withCore "/c" first firstRequired core == .ok (repaired, repairedRequired) &&
            withCore "/c" other otherRequired core == .ok (repaired, repairedRequired)) },
    { name :=
        "withCore answers a lakefile whose last require is already the running core as it is, so a repaired lakefile is a fixed point; one with no table gets the core's at its end"
      run :=
        pure
          (withCore "/c" repaired repairedRequired core == .ok (repaired, repairedRequired) &&
            withCore "/c" "name = \"c\"" #[] core ==
              .ok
                ("name = \"c\"\n\n[[require]]\nname = \"editor-core\"\npath = \"/w/lean\"\n",
                  #[{ name := "editor-core", source := .path core }])) },
    { name :=
        "the core's require is the running core's when its path resolves to it against the config directory, as the fingerprint decides: ../lean from /w/x, last, is a fixed point; lean is not the core and is replaced"
      run :=
        let at_ (directory : String) : Require :=
          { name := "editor-core", source := .path directory }
        let relative :=
          "name = \"config\"\n\n" ++ tables_ ++
            "[[require]]\nname = \"editor-core\"\npath = \"../lean\"\n\n" ++
            library
        let elsewhere :=
          "name = \"config\"\n\n" ++ tables_ ++
            "[[require]]\nname = \"editor-core\"\npath = \"lean\"\n\n" ++
            library
        pure
          (isCoreAt "/w/x" core (at_ "../lean") && !isCoreAt "/w/x" core (at_ "lean") &&
            withCore "/w/x" relative (required.push (at_ "../lean")) core ==
              .ok (relative, required.push (at_ "../lean")) &&
            withCore "/w/x" elsewhere (required.push (at_ "lean")) core ==
              .ok (repaired, repairedRequired)) },
    { name :=
        "install, remove and set a rev, each made with the core's require taken out first and written back after, answer a text whose last require is the core, an installed package before it"
      run :=
        let x : Require := { name := "x", source := .path "/p/x" }
        let gitLakefile :=
          "name = \"config\"\n\n[[require]]\nname = \"default-set\"\npath = \"/w/packages\"\n\n[[require]]\nname = \"g\"\ngit = \"https://h/g\"\nrev = \"v1\"\n"
        let gitRequired : Array Require :=
          #[required[0]!, { name := "g", source := .git "https://h/g" (some "v1") none }]
        pure
          (withCoreEdit (some core) lakefile required (install · · x) ==
              .ok
                ("name = \"config\"\n\n" ++ tables_ ++
                  "[[require]]\nname = \"x\"\npath = \"/p/x\"\n\n" ++
                  coreTable ++
                  library) &&
            withCoreEdit (some core) repaired repairedRequired (install · · x) ==
              .ok
                ("name = \"config\"\n\n" ++ tables_ ++
                  "[[require]]\nname = \"x\"\npath = \"/p/x\"\n\n" ++
                  coreTable ++
                  library) &&
            withCoreEdit (some core) lakefile required
                (remove · · "hello" "/c" (some "default-set") setRequired) ==
              .ok
                ("name = \"config\"\n\n[[require]]\nname = \"default-set\"\npath = \"/w/packages\"\n\n" ++
                  coreTable ++
                  "# My own package.\n" ++
                  library) &&
            withCoreEdit (some core) gitLakefile gitRequired (setRev · · "g" "v2") ==
              .ok
                ("name = \"config\"\n\n[[require]]\nname = \"default-set\"\npath = \"/w/packages\"\n\n[[require]]\nname = \"g\"\ngit = \"https://h/g\"\nrev = \"v2\"\n\n[[require]]\nname = \"editor-core\"\npath = \"/w/lean\"\n")) },
    { name :=
        "removing a default package expands the set without the core's require, which the root already holds: the expansion holds one editor-core, the running core's, last"
      run :=
        pure
          (withCoreEdit (some core) lakefile required
              (remove · · "compile" "/c" (some "default-set") setRequired) ==
            .ok
              ("name = \"config\"\n\n[[require]]\nname = \"shipped-themes\"\npath = \"/w/packages/shipped-themes\"\n\n# My own package.\n[[require]]\nname = \"hello\"\npath = \"../hello\"\n\n" ++
                coreTable ++
                library)) },
    { name := "an editor that knows no directory of its core refuses every edit, saying so"
      run :=
        pure
          (withCoreEdit none lakefile required
              (install · · { name := "x", source := .path "/p/x" }) ==
            .error
              "this editor knows no directory of its core, so it cannot write the lakefile's editor-core require") }]

end ModelTest
