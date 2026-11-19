import Editor.Invocation
import Editor.Process
import Editor.Workspace
import Editor.Workspace.Lister
import ModelTest.Check

/-!
# Model tests: `Editor/Workspace/Lister.lean`

The model tests of `Editor/Workspace/Lister.lean`: `workspaceListerChecks`.
The root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

namespace ListerTest

/-- The project of the checks' repository, by its normalised origin. -/
def project : Project :=
  Project.of "/r" (some "/r/.git") (some "git@github.com:o/r.git") none

/-- A workspace of the checks' project at `root` with `branch` checked out,
as the git adapter finds one; `none` for no branch, as config and the
markers find one. -/
def at_ (root : System.FilePath) (branch : Option String) : Workspace :=
  { location := .local root, branch := branch.map .named, project }

/-- A lister config declares for `scope`, running `program`. -/
def declared (scope : Workspace.ListerScope) (program : String) : Workspace.DeclaredLister :=
  { scope, program, arguments := #["-0", "--type", "f"], nul := true }

/-- The settings of the checks: git as `/usr/bin/git`, and `listers`. -/
def settings (listers : Array Workspace.DeclaredLister) : Workspace.Settings :=
  { git := "/usr/bin/git", listers }

end ListerTest

open ListerTest in
/-- The checks of which command lists a workspace's files
(`Editor/Workspace/Lister.lean`), pure: the order of the listers, their
command lines, the records made relative, and a lister as arguments. -/
def workspaceListerChecks : List Check :=
  [{  name :=
        "the lister of a workspace is config's lister for its root, else config's for its project, else git's for a workspace git found, else the fallback; a root's lister beats its project's, and a root is matched without a trailing /"
      run :=
        pure <|
          let w := at_ "/w" (some "feature")
          let r := at_ "/r" (some "main")
          let both :=
            settings #[declared (.project project.identity) "rg", declared (.root "/w/") "fd"]
          let origin (settings : Workspace.Settings) (workspace : Workspace) :=
            let chosen := Workspace.lister settings (some workspace)
            (chosen.origin, chosen.program)
          origin both w == (.config, "fd") && origin both r == (.config, "rg") &&
            origin (settings #[declared (.root "/w") "fd"]) r == (.git, "/usr/bin/git") &&
            origin (settings #[]) w == (.git, "/usr/bin/git") &&
            Workspace.lister both (some w) ==
              { origin := .config, program := "fd", arguments := #["-0", "--type", "f"]
                nul := true } },
    { name :=
        "a workspace with no branch, as config and the markers find one, a workspace that is not on this machine, and no workspace at all get the fallback lister; config's lister for the root still applies to one with no branch"
      run :=
        pure <|
          let markerFound := at_ "/m" none
          let remote : Workspace :=
            { location := .reachable "ssh" "host" "/srv/r", branch := some (.named "main")
              project }
          !Workspace.foundByGit markerFound && !Workspace.foundByGit remote &&
            Workspace.foundByGit (at_ "/w" (some "feature")) &&
            Workspace.foundByGit { at_ "/w" none with branch := some .detached } &&
            Workspace.lister (settings #[]) (some markerFound) == Workspace.Lister.fallback &&
            Workspace.lister (settings #[]) (some remote) == Workspace.Lister.fallback &&
            Workspace.lister (settings #[]) none == Workspace.Lister.fallback &&
            (Workspace.lister (settings #[declared (.root "/m") "fd"]) (some markerFound)).origin ==
              .config },
    { name :=
        "git's lister runs git ls-files -z --cached --others --exclude-standard at the root in git's environment, and the fallback find . -type f -not -path */.git/* -print0 there, both NUL-separated; config's runs its program and arguments at the root as declared"
      run :=
        pure <|
          Workspace.Lister.command (Workspace.Lister.git "git") "/w" ==
              { program := "git"
                arguments := #["ls-files", "-z", "--cached", "--others", "--exclude-standard"]
                environment := Workspace.Git.environment, directory := "/w" } &&
            Workspace.Lister.command Workspace.Lister.fallback "/x" ==
              { program := "find"
                arguments := #[".", "-type", "f", "-not", "-path", "*/.git/*", "-print0"]
                directory := "/x" } &&
            (Workspace.Lister.git "git").nul &&
            Workspace.Lister.fallback.nul &&
            Workspace.Lister.command
                (Workspace.lister (settings #[declared (.root "/w") "fd"]) (some (at_ "/w" none)))
                "/w" ==
              { program := "fd", arguments := #["-0", "--type", "f"], directory := "/w" } },
    { name :=
        "the fallback's records lose their ./ and no more; git's and config's are kept as they are"
      run :=
        pure <|
          Workspace.Lister.fallback.relative "./src/a.lean" == "src/a.lean" &&
            Workspace.Lister.fallback.relative "a/./b" == "a/./b" &&
            Workspace.Lister.fallback.relative "./" == "" &&
            (Workspace.Lister.git "git").relative "./a" == "./a" &&
            (Workspace.Lister.git "git").relative "src/b.lean" == "src/b.lean" },
    { name :=
        "the fallback declares find's exit 1, past a directory it cannot read or an entry that vanishes, a partial listing that still answers; git's and config's declare none, so any exit but 0 fails them"
      run :=
        pure <|
          let configured :=
            Workspace.lister (settings #[declared (.root "/w") "fd"]) (some (at_ "/w" none))
          Workspace.Lister.fallback.partialListing == [1] &&
            (Workspace.Lister.git "git").partialListing == [] &&
            configured.partialListing == [] },
    { name :=
        "a lister round-trips through plain arguments, git's, the fallback and config's with arguments of its own among them; arguments that are no lister decode to none"
      run :=
        pure <|
          let configured :=
            Workspace.lister (settings #[declared (.root "/w") "fd"]) (some (at_ "/w" none))
          [Workspace.Lister.git "/usr/bin/git", Workspace.Lister.fallback, configured,
                  { configured with arguments := #[] },
                  { configured with partialListing := [1, 2] }].all
              (fun lister => Workspace.Lister.ofArguments? lister.toArguments == some lister) &&
            Workspace.Lister.ofArguments? [] == none &&
            Workspace.Lister.ofArguments? configured.toArguments.dropLast == none &&
            Workspace.Lister.ofArguments? (configured.toArguments ++ [.str "x"]) == none &&
            Workspace.Lister.ofArguments? (.str "jj" :: configured.toArguments.drop 1) == none &&
            [Workspace.Lister.Origin.config, .git, .fallback].map (·.name) ==
              ["config", "git", "fallback"] }]

end ModelTest
