/-!
# The headless fixture harness: its command line

`fixture-test`, a package set's fixture harness (`lean/lakefile.lean`,
`editorFixtures`), read: the Lean toolchain's directory and the `.olean`
directories, joined with `:`, as the editor is handed them, the
repository's root, and what to do:

- `run <root>...`: discover the fixtures of each root and run each stepped,
  but those the real-thread set leaves to the CLI;
- `compared`: print the runner entries of the real-thread set, one a line,
  as `<script>\t<config>\t<expected>`, for `case_compare` in
  `tools/wiring-runs.sh`, which runs each through the CLI;
- `compare <script> <file>`: run the fixture of `script` stepped and compare
  it with the CLI's output in `file`, both ways, and with its expected file,
  exiting 1 on a difference; `case_compare` hands it each CLI run.

`real-thread [--site <prefix>]`, alone on the command line, needs no
toolchain: it prints the real-thread set's entries, all or those whose site
begins with `prefix`, as `<script>\t<site>` (`RealThread.listed`), for
reviewers holding each entry to its run in `tools/wiring-runs.sh` or
`tools/bundle-test.sh` (`.agents/rules/structure.md`, "The wiring set's
runs").

Pure: model-test pins it (`ModelTest/Editor/Test/Fixture/CommandLine.lean`).
-/

namespace Editor.Test.Fixture

/-- What the harness is asked to do. -/
inductive Command where
  /-- Run the fixtures of these discovery roots. -/
  | run (roots : Array String)
  /-- Print the fixtures the real-thread set compares both ways. -/
  | compared
  /-- Run the fixture of `script` stepped and compare it with `file`. -/
  | compare (script file : String)
  deriving DecidableEq, Repr

/-- The harness's command line, read. -/
structure Invocation where
  /-- The Lean toolchain's directory. -/
  sysroot : String
  /-- The `.olean` directories, joined with `:`. -/
  oleans : String
  /-- The repository's root. -/
  repository : String
  /-- What to do. -/
  command : Command
  deriving DecidableEq, Repr

/-- The harness's usage. -/
def usage : String :=
  "fixture-test <sysroot> <olean dirs> --repo <repository> run <root>... | compared | compare <script> <cli output file>, or fixture-test real-thread [--site <prefix>]"

/-- The command line `arguments` read, or why it cannot be. -/
def read (arguments : List String) : Except String Invocation :=
  match arguments with
  | sysroot :: oleans :: "--repo" :: repository :: rest =>
    let command : Except String Command :=
      match rest with
      | "run" :: root :: roots => .ok (.run (root :: roots).toArray)
      | ["run"] => .error "run names no discovery root"
      | ["compared"] => .ok .compared
      | ["compare", script, file] => .ok (.compare script file)
      | [] => .error "no command"
      | command :: _ => .error s!"{command} is no command"
    command.map ({ sysroot, oleans, repository, command := · })
  | [] => .error ""
  | _ => .error "expected <sysroot> <olean dirs> --repo <repository> first"

/-- The listing the command line `arguments` asks for, which needs no
toolchain: `real-thread`, with the site prefix `--site` gives, if any;
`none` for any other command line. -/
def readListing : List String → Option (Option String)
  | ["real-thread"] => some none
  | ["real-thread", "--site", prefix_] => some (some prefix_)
  | _ => none

end Editor.Test.Fixture
