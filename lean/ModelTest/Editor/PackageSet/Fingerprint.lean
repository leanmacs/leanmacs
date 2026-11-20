import Editor.PackageSet.Fingerprint
import ModelTest.Check

/-!
# Model tests: `Editor/PackageSet/Fingerprint.lean`

The model tests of `Editor/PackageSet/Fingerprint.lean`:
`packageSetFingerprintChecks`. The root module `ModelTest` runs them; its
module doc says what each shows. The manifest they read is
`tests/user-sets/manifest-git-path.json`, written by a real `lake update`
over a git dependency and a path dependency, its repository's path
shortened.
-/

namespace ModelTest

open Editor
open Editor.PackageSet

namespace FingerprintTest

/-- The manifest `lake update` wrote for a git require `x` at `v1` and a
path require `y`. -/
def manifest : String :=
  include_str "../../../../tests/user-sets/manifest-git-path.json"

/-- The config directory of the checks. -/
def config : String :=
  "/home/ada/.config/leanmacs"

/-- A lakefile's facts with the requires `requires` and the manifest
`manifest`. -/
def factsOf (required : Array Require) (manifest : Option String := none) : Facts :=
  { lakefile := .toml "" required, manifest }

end FingerprintTest

open FingerprintTest in
/-- The checks of a package set's fingerprint
(`Editor/PackageSet/Fingerprint.lean`): each require's line, a path made
absolute and normalised; the manifest's git pins, path entries left out;
the comparison, which ignores the set's name; the record's text and its
read; the shipped default's; and a `lakefile.lean` known by its hash. -/
def packageSetFingerprintChecks : List Check :=
  [{  name :=
        "a require's line is path, git or reservoir, a path made absolute against the config directory and normalised, an absent rev, subDir or version written -"
      run :=
        pure
          (({ name := "a", source := .path "../packages/a" } : Require).line config ==
              "path a /home/ada/.config/packages/a" &&
            ({ name := "b", source := .path "/x/./y//z/../b" } : Require).line config ==
              "path b /x/y/b" &&
            ({ name := "c", source := .git "https://h/c.git" (some "v1") none } : Require).line
                config ==
              "git c https://h/c.git v1 -" &&
            ({ name := "d", source := .git "https://h/d" none (some "sub") } : Require).line
                config ==
              "git d https://h/d - sub" &&
            ({ name := "e", source := .reservoir "leanprover" none } : Require).line config ==
              "reservoir e leanprover -" &&
            normalise "/" "../../a" == "/a") },
    { name :=
        "the pins are the manifest's git entries, name, url and the commit, and its path entries are left out; a text that is no manifest has none"
      run :=
        pure
          (pins (some manifest) ==
              #["pin x file:///tmp/user-sets/repo 6aed424a2714d1ff73c6335b847bd771b6054be3"] &&
            (gitEntries manifest).map (·.inputRev) == #[some "v1"] &&
            pins (some "not json") == #[] &&
            pins none == #[]) },
    { name :=
        "two fingerprints are of one set when their required and pins are the same, whatever set name they carry; a require more, or a pin moved, is another set"
      run :=
        let one :=
          (Fingerprint.ofFacts config (factsOf #[{ name := "a", source := .path "a" }]) (some "s")
            none)
        let other :=
          (Fingerprint.ofFacts config (factsOf #[{ name := "a", source := .path "a" }]) none none)
        let more :=
          Fingerprint.ofFacts config
            (factsOf #[{ name := "a", source := .path "a" }, { name := "b", source := .path "b" }])
            none none
        let pinned :=
          Fingerprint.ofFacts config
            (factsOf #[{ name := "a", source := .path "a" }] (some manifest)) none none
        match one, other, more, pinned with
        | some one, some other, some more, some pinned =>
          pure (same one other && !same one more && !same one pinned)
        | _, _, _, _ => pure false },
    { name :=
        "a manifest that differs only in its path entries, as the language server writes them, is the same set"
      run :=
        let pathOnly :=
          "{\"version\": \"1.3.0\", \"packages\": [{\"type\": \"path\", \"name\": \"y\", \"dir\": \"../local\"}], \"name\": \"config\"}"
        let required : Array Require := #[{ name := "y", source := .path "../local" }]
        match Fingerprint.ofFacts config (factsOf required) none none,
          Fingerprint.ofFacts config (factsOf required (some pathOnly)) none none with
        | some without, some withPaths => pure (same without withPaths)
        | _, _ => pure false },
    { name :=
        "the record editor.packages holds the version, the required, the pins and the set, and reads back to the same fingerprint; another version or an unknown line reads as none"
      run :=
        let fingerprint : Fingerprint :=
          { required := #["path a /x/a", "git b https://h/b - -"]
            pins := #["pin b https://h/b 0123"], set := some "default-set" }
        pure
          (fingerprint.text ==
              "leanmacs-packages 1\nrequire path a /x/a\nrequire git b https://h/b - -\npin b https://h/b 0123\nset default-set\n" &&
            Fingerprint.parse? fingerprint.text == some fingerprint &&
            Fingerprint.parse? "leanmacs-packages 2\n" == none &&
            Fingerprint.parse? "leanmacs-packages 1\nwhat\n" == none) },
    { name :=
        "the shipped default's fingerprint is the generated lakefile's: one path require of its set and no pin, so a generated lakefile matches it"
      run :=
        let generated : Array Require := #[{ name := "default-set", source := .path "/w/packages" }]
        match Fingerprint.ofFacts config (factsOf generated) none none with
        | some fingerprint =>
          pure
            (same fingerprint (shipped "default-set" "/w/packages") &&
              (shipped "default-set" "/w/packages").set == some "default-set")
        | none => pure false },
    { name :=
        "a lakefile.lean is known by the hash of its text, so any edit is another set; no lakefile, or one that cannot be read, has no fingerprint"
      run :=
        let of (text : String) := Fingerprint.ofFacts config { lakefile := .lean text } none none
        match of "import Lake\n", of "import Lake\n", of "import Lake\n-- edited\n" with
        | some a, some b, some c =>
          pure
            (same a b && !same a c && Fingerprint.ofFacts config {} none none == none &&
              Fingerprint.ofFacts config { lakefile := .unreadable "no" } none none == none)
        | _, _, _ => pure false },
    { name :=
        "a root editor-core require by the running editor's own core directory is left out of the fingerprint, however its path is spelled; one naming another directory, or the core from git, is kept"
      run :=
        let set : Require := { name := "default-set", source := .path "/w/packages" }
        let own : Require := { name := "editor-core", source := .path "../../../../w/x/../lean" }
        let other : Require := { name := "editor-core", source := .path "/elsewhere/lean" }
        let git : Require :=
          { name := "editor-core",
            source := .git "https://h/leanmacs" (some "nightly-1") (some "lean") }
        let of (required : Array Require) :=
          (Fingerprint.ofFacts config (factsOf required) none (some "/w/lean")).map (·.required)
        pure
          (of #[own, set] == some #["path default-set /w/packages"] &&
            of #[other, set] ==
              some #["path editor-core /elsewhere/lean", "path default-set /w/packages"] &&
            of #[git, set] ==
              some
                #["git editor-core https://h/leanmacs nightly-1 lean",
                  "path default-set /w/packages"] &&
            (Fingerprint.ofFacts config (factsOf #[own, set]) none none).map (·.required) ==
              some #["path editor-core /w/lean", "path default-set /w/packages"]) },
    { name :=
        "the lakefile generated before the core was required at the root, and the one generated now, both fingerprint as the shipped default's, so neither starts a build"
      run :=
        let set : Require := { name := "default-set", source := .path "/w/packages" }
        let core : Require := { name := "editor-core", source := .path "/w/lean" }
        match Fingerprint.ofFacts config (factsOf #[set]) none (some "/w/lean"),
          Fingerprint.ofFacts config (factsOf #[core, set]) none (some "/w/lean") with
        | some old, some new =>
          pure
            (same old (shipped "default-set" "/w/packages") &&
              same new (shipped "default-set" "/w/packages"))
        | _, _ => pure false },
    { name := "a manifest's quoted names are read unquoted"
      run := pure (unquoted "«default-set»" == "default-set" && unquoted "plain" == "plain") }]

end ModelTest
