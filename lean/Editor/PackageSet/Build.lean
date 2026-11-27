import Editor.Api
import Editor.Job
import Editor.Jumps
import Editor.PackageSet.Layout
import Editor.PackageSet.Running
import Editor.Process
import Editor.Restore.Restart

/-!
# The package-set build, as a job

A user's package set is built by the job `package-build`
(`docs/design/packages.md`, "User package sets"). A reload whose
fingerprint differs from the running editor's starts it (`decide`, which
the reload reducer asks as each reload finishes, `Config.State.packagesAfter`), and so does `:package-update`
(the package `package-set`, `packages/package-set/`). It runs over the job port's process
and file requests alone, so every decision it makes is pinned on the job
and process models (`ModelTest.packageSetBuildChecks`), the exact commands,
arguments and environments among them.

## When a reload starts it (`decide`)

None is started when a build is in flight, when the config has no
lakefile that can be read, when the running editor knows no fingerprint of
its own, no data directory, no core identity or no core directory, or
when the fingerprints are the same (`same`). With no `lake` it starts none and says
`packages: the package set changed, but this editor has no lake to build
it (<sysroot>/bin/lake)`. Otherwise it starts one with an order (`Order`):
the config directory, the `lake`, the data directory, the running
executable, the build environment (`editor.build`), the requires'
lines for the record, the shipped set's name, the requires fetched with
git, the requires to resolve (`resolveNames`) and the running editor's
core directory.

## The steps, in order

1. **Git**, when the lakefile directly names a git or Reservoir
   dependency: `git --version`. Not found, or a non-zero exit (macOS's
   command-line-tools shim), stops the build with `gitRequired`.
2. **Resolve**: `lake update --keep-toolchain <names>` for the requires
   missing from the manifest, whose entry disagrees with the lakefile's
   url or rev, or, for a path require, whose entry is not a path entry
   naming the same directory (`resolveNames`); for `:package-update`, the
   named package, or every git and Reservoir require.
2b. **Core**: the manifest, `<config>/lake-manifest.json`, is read once,
   here, and must resolve `editor-core` to the running editor's own core: a
   path entry whose directory, normalised lexically against the config
   directory, is the core directory (`coreRefusal?`,
   `Fingerprint.coreEntry?`). The root's own require and the set's
   inherited `<set>/../lean` both pass. A git entry, a path at another
   directory or no entry stops the build before anything is linked or a
   staging directory made: `the package set resolves editor-core to <git
   <url> at <rev> | the directory <dir> | nothing>, not this editor's core
   <core>; require it at the root of <config>/lakefile.toml with path =
   "<core>", as its last require, after every other (:package-install
   and :package-remove write it), then :reload`. A git core may already have
   been fetched by the resolve: the manifest is authoritative only after
   it.
3. **Rust**: `lake query :editorRustCrates`, then, when the set holds a
   package with a Rust crate, `cargo --version`. A set with no crate needs
   no Cargo: its link reuses the core's archive as it is built
   (`rustSource` in `lean/lakefile.lean`; the editor never ships Cargo,
   decided 2026-11-20). One with a crate needs the user's own, and a
   missing or broken one stops the build with `cargoRequired`, naming the
   package's crate. A package whose native code is a library of its own
   (an `editorLibrary` target) adds no crate, so a set whose packages
   declare only libraries needs no Cargo here: an already-built library
   runs no tool at all.
4. **Build and install**: `lake build :editorInstall` with
   `EDITOR_INSTALL_DIR=<data>/editors/staging-<k>` (`nextStaging`) and the build
   environment, its output streamed into the build buffer. The install
   stages each package's library beside the new editor (`editorLibraries`
   in `lean/lakefile.lean`). A library target that must build and finds
   its tool missing stops the build with the core's sentence, `<tool> is
   required to build <package>'s library, and none works here (<how>): …`,
   which `missingTooling?` reads off Lake's `error:` line, so the failure
   line is `lake build exited with status 1: <sentence>`.
5. **Record**: the new editor's `editor.core` is read, and
   `editor.packages` written beside it: the requires, the pins of the
   manifest the core check read after the resolve, and the set's name.
6. **Probe**: `<staging>/editor --probe`, within 10 s, must print `probe:
   ok`, which catches a bad link, a bad signature or an `initialize` that
   throws before anything is published. A probe that did not pass fails
   the build with `probeFailed`'s text, which carries the first line the
   probe wrote to standard error: an initialiser's uncaught error, such as
   a package's library that was refused, as Lean's generated `main` prints
   it.
7. **Publish**: `/bin/mv <staging> <data>/editors/<core>/<n>`.
8. **Prune**: `/bin/rm -rf` for each directory `pruned` names, never the
   one that holds the running executable.
9. **Restart** into the new editor (`Editor.restart`), or, with no state
   directory, `packages: built <exe>; it starts at the next launch`.

Every command of the build runs in the config directory with the editor's
own environment, less the variables that would choose another toolchain
or compiler (`clearedVariables`: `LEAN_CC`, `LEAN_SYSROOT`, `CC` and the
rest), and the build environment set over it, the probe and the file
moves from `/`. So `lake` is the order's, by absolute path, and Lake finds
`lean` and `clang` beside it, whatever the user's shell set. **Every failure** removes the staging directory, ends
the buffer with `Package build failed: <how> after <t>`, says `packages:
<how>; this editor keeps running` and publishes nothing.

## The buffer

`*package-build*` (`bufferName`) is made read-only by the job's first post
(`startedName`), its text replaced by a header line, and shown through the
display rules for the opener `package-build`; output is appended as it
arrives, one post for each delivery of the child's lines, and the job's
end appends `Package build finished after <t>` or `Package build failed:
<how> after <t>`.
-/

namespace Editor.PackageSet

/-- The job that builds a user's package set, and the key it runs under. -/
def buildJob : String :=
  "package-build"

/-- The command the build's first post runs: it makes the buffer and shows
it. -/
def startedName : String :=
  "package-build-started"

/-- The command the build's output is posted to. -/
def outputName : String :=
  "package-build-output"

/-- The build's buffer. -/
def bufferName : String :=
  "*package-build*"

/-- The opener the build's buffer is shown for, by the display rules. -/
def opener : String :=
  "package-build"

/-- The most bytes a line of a child's output may be. -/
def lineBound : Nat :=
  65536

/-- How long `git --version` and `cargo --version` may take. -/
def checkPatience : Nat :=
  10000

/-- How long `lake query :editorRustCrates` may take. -/
def queryPatience : Nat :=
  120000

/-- How much of a run's output is kept. -/
def runLimit : Nat :=
  1048576

/-- What a build is to do, as the job's argument carries it. -/
structure Order where
  /-- The config directory, absolute: the set's root. -/
  config : String
  /-- The toolchain's `lake`. -/
  lake : String
  /-- The data directory. -/
  data : String
  /-- The running executable, whose directory is never pruned. -/
  running : String
  /-- The build environment, set over the editor's own. -/
  environment : Array (String × String) := #[]
  /-- The requires' lines, for the record. -/
  required : Array String := #[]
  /-- The shipped set's name, for the record. -/
  set : Option String := none
  /-- The requires fetched with git, by name. -/
  fetched : Array String := #[]
  /-- The requires to resolve, by name; none for no `lake update`. -/
  resolve : Array String := #[]
  /-- The directory of the running editor's core, which the set's manifest
  must resolve `editor-core` to (the core check). -/
  core : String := ""
  deriving DecidableEq, Repr, BEq, Inhabited

/-- The order as the text the job is started with: one `key value` a
line. -/
def Order.encode (order : Order) : String :=
  let lines :=
    #[s!"config {order.config}", s!"lake {order.lake}", s!"data {order.data}",
        s!"running {order.running}"] ++
      order.environment.map (fun (name, value) => s!"env {name}={value}") ++
      order.required.map ("require " ++ ·) ++
      (order.set.map ("set " ++ ·)).toArray ++
      order.fetched.map ("fetched " ++ ·) ++
      order.resolve.map ("resolve " ++ ·) ++
      #[s!"core {order.core}"]
  String.join (lines.toList.map (· ++ "\n"))

/-- The order `text` encodes (`Order.encode`); none for a text that is not
one. -/
def Order.decode? (text : String) : Option Order := do
  let lines := (text.splitOn "\n").filter (!·.isEmpty)
  let value (key : String) : Option String :=
    (lines.find? (·.startsWith (key ++ " "))).map fun line => (line.drop (key.length + 1)).toString
  let all (key : String) : Array String :=
    (lines.filterMap fun line =>
        if line.startsWith (key ++ " ") then some (line.drop (key.length + 1)).toString
        else none).toArray
  let environment :=
    (all "env").filterMap fun pair =>
      match pair.splitOn "=" with
      | name :: rest => some (name, "=".intercalate rest)
      | [] => none
  return {
      config := ← value "config", lake := ← value "lake", data := ← value "data"
      running := ← value "running", environment, required := all "require", set := value "set"
      fetched := all "fetched", resolve := all "resolve", core := ← value "core" }

/-- The requires to resolve with `lake update`, for the config directory
`config`: those whose name the manifest holds no entry of; the git ones
whose entry has another url, or another revision than the lakefile asks
for; and the path ones whose entry is not a path entry naming the same
directory (both normalised lexically against `config`). Lake keeps a
stale entry when a require's source kind changes, and only warns (probed
on Lake 4.35.0): a root `editor-core` by path over the git or inherited
entry a set had before. -/
def resolveNames (required : Array Require) (manifest : Option String) (config : String := "/") :
    Array String :=
  let entries : Array (String × Json.Value) :=
    match manifest.map (Json.parse ·.toUTF8) with
    | some (.ok document) =>
      match document.field? "packages" with
      | some (.array items) =>
        items.filterMap fun (item : Json.Value) =>
          match item.field? "name" with
          | some (.string name) => some (unquoted name, item)
          | _ => none
      | _ => #[]
    | _ => #[]
  let pinned := (manifest.map gitEntries).getD #[]
  (required.filter fun require =>
        match entries.find? (·.1 == require.name) with
        | none => true
        | some (_, entry) =>
          match require.source, pinned.find? (·.name == require.name) with
          | .git url rev _, some pin => pin.url != url || (rev.isSome && pin.inputRev != rev)
          | .path directory, _ =>
            match entry.field? "type", entry.field? "dir" with
            | some (.string "path"), some (.string dir) =>
              normalise config dir != normalise config directory
            | _, _ => true
          | _, _ => false).map
    (·.name)

/-- Why the build of the set in the config directory `config` stops before
it links, when its manifest, whose text is `manifest`, resolves
`editor-core` to anything but the running editor's core at `core`: a path
entry naming another directory (`namesCore`, as the fingerprint and the
edits decide), a git entry, or none ("The steps", in the module docs).
None when it resolves that
core, whatever the entry's spelling: the root's own require, or the set's
inherited `<set>/../lean`. -/
def coreRefusal? (config core : String) (manifest : Option String) : Option String :=
  let resolved :=
    match manifest.bind Fingerprint.coreEntry? with
    | some (.path directory) =>
      if namesCore config core directory then none
      else some s!"the directory {normalise config directory}"
    | some (.git url rev _) => some s!"git {url} at {rev}"
    | none => some "nothing"
  resolved.map fun what =>
    s!"the package set resolves editor-core to {what}, not this editor's core {core}; require it at the root of {config}/lakefile.toml with path = \"{core}\", as its last require, after every other (:package-install and :package-remove write it), then :reload"

/-- What a reload is to do about the package set (`decide`). -/
inductive Decision where
  /-- Nothing. -/
  | nothing
  /-- Say this, and build nothing. -/
  | say (text : String)
  /-- Start the build with this order. -/
  | build (order : Order)
  deriving DecidableEq, Repr

/-- What is said when the set changed and there is no `lake`. -/
def noLake (running : Running) : String :=
  let where_ := (running.sysroot.map (· ++ "/bin/lake")).getD "no Lean toolchain"
  s!"packages: the package set changed, but this editor has no lake to build it ({where_})"

/-- The order of a build for the running editor `running` of the config
whose facts are `facts`, resolving `resolve`; or why none can start: an
empty reason for one that starts silently. -/
def orderOf (running : Running) (facts : Facts) (resolve : Option (Array String) := none) :
    Except String Order := do
  let some fingerprint :=
    Fingerprint.ofFacts running.config facts running.setName running.coreDirectory
    | throw ""
  let some data := running.data | throw ""
  let some _ := running.core | throw ""
  let some core := running.coreDirectory | throw ""
  let some lake := running.lake | throw (noLake running)
  let required :=
    match facts.lakefile with
    | .toml _ required => required
    | _ => #[]
  let fetched := (required.filter (·.source.fetched)).map (·.name)
  return {
      config := running.config, lake, data, running := running.executable
      environment := running.build, required := fingerprint.required, set := running.setName
      fetched, resolve := resolve.getD (resolveNames required facts.manifest running.config), core }

/-- What a reload is to do about the package set, given what the running
editor knows of its own (`running`), what the reload read (`facts`) and
whether a build is in flight ("When a reload starts it", in the module
docs). -/
def decide (running : Running) (facts : Facts) (inFlight : Bool) : Decision :=
  if inFlight then .nothing
  else
    match running.fingerprint,
      Fingerprint.ofFacts running.config facts running.setName running.coreDirectory with
    | some own, some config =>
      if same own config then .nothing
      else
        match orderOf running facts with
        | .ok order => .build order
        | .error "" => .nothing
        | .error text => .say text
    | _, _ => .nothing

/-- What is said when the build starts. -/
def startedLine : String :=
  s!"packages: the package set changed; building it (see {bufferName})"

/-- The variables removed from the environment of every command the build
runs in the config directory, before the build record is set over it: what
would make Lake, or the tools it runs, take another toolchain, compiler or
search path than the running editor's own (`docs/design/packages.md`, "The
build, as a job"). Lake finds `lean` and `clang` beside the `lake` the
order names; `LEAN_CC` and the rest would override that from the user's
shell. A record that holds one of them, a checkout's `LEAN_CC`, still sets
it, since the record is set after. -/
def clearedVariables : Array String :=
  #["LEAN_CC", "LEAN_AR", "LEAN_SYSROOT", "LEAN", "LEAN_PATH", "LEAN_SRC_PATH", "LAKE_HOME",
    "LAKE_OVERRIDE_LEAN", "ELAN_TOOLCHAIN", "CC", "AR"]

/-- The build environment of `order`, over the editor's own, with
`clearedVariables` removed first. -/
def Order.environmentOf (order : Order) (more : Array (String × String) := #[]) :
    Process.Environment :=
  { unset := clearedVariables, set := order.environment ++ more }

/-- `program --version`, in the config directory with the build
environment: the check that a tool works. -/
def toolCommand (order : Order) (program : String) : Process.Command :=
  { program, arguments := #["--version"], environment := order.environmentOf
    directory := order.config }

/-- `lake <arguments>`, in the config directory with the build
environment. -/
def lakeCommand (order : Order) (arguments : Array String) (more : Array (String × String) := #[]) :
    Process.Command :=
  { program := order.lake, arguments, environment := order.environmentOf more
    directory := order.config }

/-- A command of the build's own that runs from `/`: the probe, `mv`,
`rm` and `cat`. -/
def rootCommand (program : String) (arguments : Array String) : Process.Command :=
  { program, arguments, directory := "/" }

/-- What is said when git is needed for `names` and none works (`how`). -/
def gitRequired (names : Array String) (how : String) : String :=
  s!"git is required to fetch {", ".intercalate names.toList}, and none works here ({how}): install it with `xcode-select --install` on macOS, or from https://git-scm.com, then :reload"

/-- What is said when Cargo is needed and none works (`how`), for the
crates `crates` (each its package and its crate). -/
def cargoRequired (crates : Array (String × String)) (how : String) : String :=
  let what :=
    ", ".intercalate (crates.toList.map fun (owner, crate) => s!"{owner}'s Rust crate {crate}")
  s!"Cargo is required to build {what}, and none works here ({how}): install it with rustup from https://rustup.rs, then :reload"

/-- How a run ended, as a clause. -/
def Ended.describe : Process.Exit → String
  | .code n => s!"exited with status {n}"
  | .signal n => s!"was ended by the signal {n}"

/-- The text of `line` between the first `before` and the next `after` in
it, when both are there. -/
def between? (line before after : String) : Option String :=
  match line.splitOn before with
  | _ :: rest :: _ =>
    match rest.splitOn after with
    | inside :: _ :: _ => some inside
    | _ => none
  | _ => none

/-- The sentence a line of a failed build's output carries when a package's
library target found its tool missing: the line Lake prints for the core's
staging of the set's libraries, `error: <tool> is required to build
<package>'s library, and none works here (<how>): …`
(`libraryToolRequired` in `lean/lakefile.lean`), from the tool on; none for
any other line. -/
def libraryToolRequired? (line : String) : Option String :=
  if
      (line.splitOn " is required to build ").length > 1 &&
        (line.splitOn "'s library, and none works here (").length > 1 then
    some
      (match line.splitOn "error: " with
        | _ :: rest@(_ :: _) => "error: ".intercalate rest
        | _ => line).trimAscii.toString
  else none

/-- What a line of a failed build's output says is missing of the system's
tooling: a header of the system's C library or SDK, or a framework or a
library the link lacks (`missingTooling?`). -/
def missingSystemTooling? (line : String) : Option String :=
  let install :=
    "the app ships the Lean toolchain alone: install the Xcode command line tools (`xcode-select --install`) for a package whose build uses them, or use the package's prebuilt binary, as its documentation says"
  match between? line "fatal error: '" "' file not found" with
  | some header =>
    some s!"a package's C includes <{header}>, a header of the system's C library or SDK; {install}"
  | none =>
    match between? (line ++ "\n") "framework not found for -framework " "\n" with
    | some framework =>
      some s!"a package links the system framework {framework.trimAscii}; {install}"
    | none =>
      match between? (line ++ "\n") "library not found for -l" "\n" with
      | some library => some s!"a package links the system library {library.trimAscii}; {install}"
      | none => none

/-- What a line of a failed build's output says is missing of the tooling a
package's native code needs, with how to get it; none for any other line.
The app ships the Lean toolchain alone, with no C library headers, no
macOS SDK beyond the link stubs of what the shipped editor links, and no
Cargo (decided 2026-11-20), so a package with native code needs the
user's own tooling or a prebuilt binary its lakefile fetches
(`docs/design/packages.md`, "Who can build it"). It knows the compiler's
missing header (`fatal error: '<h>' file not found`) and the linker's
missing framework or library (`framework not found for -framework <F>`,
`library not found for -l<L>`), and a package's library target whose tool
is missing: the line Lake prints for the core's staging of the set's
libraries, `error: <tool> is required to build <package>'s library, and
none works here (<how>): …` (`libraryToolRequired` in `lean/lakefile.lean`),
answered as that sentence. -/
def missingTooling? (line : String) : Option String :=
  (libraryToolRequired? line).orElse fun _ => missingSystemTooling? line

/-- The app bundle the toolchain's `lake` at `lake` is in, when it is a
bundle's: `<bundle>/Contents/Resources/lean/toolchain/bin/lake`. -/
def bundleOfLake? (lake : String) : Option String :=
  let suffix := "/Contents/Resources/lean/toolchain/bin/lake"
  if lake.endsWith suffix then some (lake.dropEnd suffix.length).toString else none

/-- What is said when the bundle's `lake` at `lake` failed as macOS
refusing to run it does (`how`): killed at its start (the signal 9), or
refused (`Operation not permitted`). A downloaded app's files are
quarantined, and after the app is opened its nested tools may still be
refused; removing the flag lets them run (`packaging/macos/README.txt`).
None for a `lake` outside a bundle, or any other failure. -/
def refusedToolchain? (lake how : String) : Option String := do
  let bundle ← bundleOfLake? lake
  guard (how == Ended.describe (.signal 9) || (how.splitOn "not permitted").length > 1)
  return s!"macOS refused to run the bundled toolchain ({lake}); remove the quarantine flag: xattr -dr com.apple.quarantine {bundle}"

/-- How a step of the build that runs `lake` failed: macOS refused to run
the bundle's `lake` (`refusedToolchain?`'s text), or it ended any other
way (`how`). -/
inductive LakeFailure where
  /-- macOS refused to run it; `text` says so and what to do. -/
  | refused (text : String)
  /-- It ended as `how` says. -/
  | ended (how : String)
  deriving DecidableEq, Repr

/-- How a run of the `lake` at `lake` that failed as `how` failed: the one
place the build decides that macOS refused it (`refusedToolchain?`). -/
def LakeFailure.of (lake how : String) : LakeFailure :=
  match refusedToolchain? lake how with
  | some text => .refused text
  | none => .ended how

/-- What the build says of the step `step` that failed as `failure`: a
refusal as it is, whichever step it stopped, else the step followed by how
it ended. -/
def LakeFailure.describe (failure : LakeFailure) (step : String) : String :=
  match failure with
  | .refused text => text
  | .ended how => s!"{step} {how}"

/-- The lines of `frames`, decoded. -/
def framesOf : Process.Frames → Array String
  | .lines lines => lines.map File.decodeBytes
  | .bytes _ => #[]

/-- How long `milliseconds` is, said as compile says it. -/
def elapsed (milliseconds : Nat) : String :=
  let seconds := milliseconds / 1000
  if seconds < 60 then s!"{seconds}.{(milliseconds % 1000) / 100} s"
  else s!"{seconds / 60} min {seconds % 60} s"

/-- The header line of the build's buffer. -/
def header (order : Order) : String :=
  s!"Package build of {order.config}"

/-- Appends `lines`, each ended with a line feed, to the build's buffer,
each view of it whose cursor is on its last line following. -/
def appendLines (lines : Array String) : EditorM Unit := do
  if lines.isEmpty then
    return
  let some id ← findBuffer bufferName | return
  let .ok text ← id.text | return
  let count ← text.lineCount
  let length ← text.byteLength
  let state ← editorState
  let mut followers := #[]
  for window in state.windows.filter (·.buffer == id) do
    if let .ok selection← window.id.selection then
      let head := (selection.ranges[selection.primary]?.map (·.head)).getD 0
      if (← text.pointOf head).row + 1 ≥ count then
        followers := followers.push window.id
  id.writing do
      text.insert length (String.join (lines.map (· ++ "\n")).toList)
  let last ← text.offsetOf { row := (← text.lineCount) - 1, column := 0 }
  for view in followers do
    Jumps.placeCursor view last

/-- The command of the build's first post: the build buffer made, or its
text replaced by the header line, and shown ("The buffer", in the module
docs). It is here, beside the job that posts to it, so that whoever
registers the job registers its commands: the package `package-set`
(`packages/package-set/`), and the kit's stand-in
(`Editor/Test/PackageSet.lean`). -/
def startedCommand (call : Call) : EditorM Unit := do
  let .str line :: _ := call.arguments | return
  let id ←
    match ← findBuffer bufferName with
    | some id =>
      let .ok text ← id.text | return
      id.writing do
          text.replaceRange 0 (← text.byteLength) (line ++ "\n")
      pure id
    | none =>
      let .ok id ← createBuffer bufferName (line ++ "\n") | return
      discard <| id.setReadOnly true
      pure id
  discard <| id.display call.target.window.id opener (focus := false)

/-- The command the build's output is posted to: its lines appended. -/
def outputCommand (call : Call) : EditorM Unit :=
  appendLines
    (call.arguments.toArray.filterMap fun
      | .str line => some line
      | _ => none)

/-- What a failed build does ("The steps", in the module docs): its last
line appended, and the failure said. -/
def failed (how : String) (milliseconds : Nat) : EditorM Unit := do
  appendLines #[s!"Package build failed: {how} after {elapsed milliseconds}"]
  message s!"packages: {how}; this editor keeps running"

/-- What a build that published `executable` does: its last line appended,
then the restart into it, or, with no state directory, that it starts at
the next launch. -/
def succeeded (executable : String) (milliseconds : Nat) : EditorM Unit := do
  appendLines #[s!"Package build finished after {elapsed milliseconds}"]
  if (← editorState).stateDirectory.isSome then
    Editor.restart (into := some executable)
  else
    message s!"packages: built {executable}; it starts at the next launch"

/-- How the build fails when its probe of the new editor (`probe`) did not
pass: `the new editor did not start: ` and how (`Restore.probeFailure`), or
none when it passed. -/
def probeFailed (probe : Except ProcessError Process.Ran) : Option String :=
  let how :=
    match probe with
    | .error error => some error.describe
    | .ok ran => Restore.probeFailure ran
  how.map fun how => s!"the new editor did not start: {how}"

/-- Runs `command` to its end within `time`: how it failed, or what it
wrote. -/
def runOf (command : Process.Command) (time : Nat) : JobM (Except String Process.Ran) := do
  match ← Process.request (.runWithin command runLimit time) with
  | .error error =>
    return .error error.describe
  | .ok ran =>
    return .ok ran

/-- Whether the tool `program` works: none when `--version` exits 0, else
how it failed. -/
def toolFailure (order : Order) (program : String) : JobM (Option String) := do
  match ← runOf (toolCommand order program) checkPatience with
  | .error how =>
    return some how
  | .ok { exit := .code 0, .. } =>
    return none
  | .ok ran =>
    return some (Ended.describe ran.exit)

/-- Runs `command` as a streaming child, posting its lines to the buffer
as they come: none when it exits 0, else how it failed (`LakeFailure.of`):
for a bundle's `lake` that macOS refused to run, that; else how it ended,
followed by what its output said is missing of a package's native tooling
(`missingTooling?`). -/
def streamed (command : Process.Command) : JobM (Option LakeFailure) := do
  match
    ←
      Process.request
          (.start command { stdout := .lines, stderr := .lines, bound := lineBound }) with
  | .error error =>
    return some (LakeFailure.of command.program error.describe)
  | .ok child =>
    -- What the output said is missing of a package's native tooling, at
    -- its first line that says so.
    let mut missing : Option String := none
    for _ in [0:1000000000] do
      match ← Process.read child with
      | .error error =>
        return some (.ended error.describe)
      | .ok delivery =>
        let lines := framesOf delivery.stdout ++ framesOf delivery.stderr
        unless lines.isEmpty do
          post { command := outputName, arguments := lines.toList.map .str }
        if missing.isNone then
          missing := lines.findSome? missingTooling?
        match delivery.ended with
        | some (.exited (.code 0)) =>
          return none
        | some (.exited exit) =>
          let how := Ended.describe exit
          return some
              (match LakeFailure.of command.program how with
              | .refused text => .refused text
              | .ended how => .ended ((missing.map (s!"{how}: " ++ ·)).getD how))
        | some (.lineTooLong _ bound) =>
          return some (.ended s!"wrote a line longer than {bound} bytes")
        | some (.failed detail) =>
          return some (.ended detail)
        | none =>
          pure ()
    return some (.ended "it never ended")

/-- The text of the file at `path`, read with `cat`; none when it cannot be
read. -/
def readText (path : String) : JobM (Option String) := do
  match ← runOf (rootCommand "/bin/cat" #[path]) checkPatience with
  | .ok { exit := .code 0, stdout, .. } =>
    return String.fromUTF8? stdout
  | _ =>
    return none

/-- The crates `lake query :editorRustCrates` printed: each line's package
and crate. -/
def cratesIn (text : String) : Array (String × String) :=
  ((text.splitOn "\n").filterMap fun line =>
      match line.splitOn "\t" with
      | owner :: crate :: _ => some (owner, crate)
      | _ => none).toArray

/-- The job `package-build` ("The steps", in the module docs). Its
argument is the order's text (`Order.encode`). -/
def buildWork (arguments : List Argument) : Work := fun _ => do
  let .str text :: _ := arguments | throw s!"{buildJob}: its arguments are not an order"
  let some order := Order.decode? text | throw s!"{buildJob}: its arguments are not an order"
  let started ← now
  let fail (how : String) : JobM (EditorM Unit) := do
    return failed how ((← now) - started)
  post { command := startedName, arguments := [.str (header order)] }
  -- 1. Git, for a dependency fetched with it.
  unless order.fetched.isEmpty do
    if let some how← toolFailure order "git" then
      return ← fail (gitRequired order.fetched how)
  -- 2. Resolve.
  unless order.resolve.isEmpty do
    if let some failure←
        streamed (lakeCommand order (#["update", "--keep-toolchain"] ++ order.resolve)) then
      return ← fail (failure.describe "lake update")
  -- 2b. Core: the manifest, read once here, must resolve the running core.
  let manifest ← readText (order.config ++ "/lake-manifest.json")
  if let some how := coreRefusal? order.config order.core manifest then
    return ← fail how
  -- 3. Rust: the set's crates, then Cargo, which every link runs.
  let crates ←
    match ← runOf (lakeCommand order #["query", ":editorRustCrates"]) queryPatience with
    | .error how =>
      return ←
          fail
              ((LakeFailure.of order.lake how).describe
                "lake query :editorRustCrates could not run:")
    | .ok ran =>
      match ran.exit with
      | .code 0 =>
        pure (cratesIn ((String.fromUTF8? ran.stdout).getD ""))
      | exit =>
        let said := ((String.fromUTF8? ran.stderr).getD "").splitOn "\n" |>.filter (!·.isEmpty)
        post { command := outputName, arguments := said.map .str }
        return ←
            fail
                ((LakeFailure.of order.lake (Ended.describe exit)).describe
                  "lake query :editorRustCrates")
  unless crates.isEmpty do
    if let some how← toolFailure order "cargo" then
      return ← fail (cargoRequired crates how)
  -- 4. Build and install into a staging directory.
  discard <| File.makeDirectory (editorsDirectory order.data)
  let present :=
    match ← File.list (editorsDirectory order.data) with
    | .ok entries => entries.map (·.name)
    | .error _ => #[]
  let staging := stagingDirectory order.data (nextStaging present)
  let removeStaging : JobM Unit :=
    discard <| runOf (rootCommand "/bin/rm" #["-rf", staging]) checkPatience
  if let some failure←
      streamed
        (lakeCommand order #["build", ":editorInstall"] #[("EDITOR_INSTALL_DIR", staging)]) then
    removeStaging
    return ← fail (failure.describe "lake build")
  -- 5. The new editor's core, and its record.
  let some core := (← readText (staging ++ "/editor.core")).bind coreIn
    |
    removeStaging
    return ← fail s!"the build wrote no {staging}/editor.core"
  let record : Fingerprint :=
    { required := order.required, pins := pins manifest, set := order.set }
  -- The install made the directory; asking again is no error.
  discard <| File.makeDirectory staging
  if let .error error← File.append (staging ++ "/editor.packages") record.text.toUTF8 then
    removeStaging
    return ← fail s!"{staging}/editor.packages could not be written: {error.describe}"
  -- 6. The probe.
  let probe ←
    Process.request
        (.runWithin (rootCommand (staging ++ "/editor") #["--probe"]) 65536 Restore.probePatience)
  if let some how := probeFailed probe then
    removeStaging
    return ← fail how
  -- 7. Publish.
  let directory := coreDirectory order.data core
  discard <| File.makeDirectory directory
  let names :=
    match ← File.list directory with
    | .ok entries => entries.map (·.name)
    | .error _ => #[]
  let n := nextVersion names
  let target := versionDirectory order.data core n
  match ← runOf (rootCommand "/bin/mv" #[staging, target]) checkPatience with
  | .ok { exit := .code 0, .. } =>
    pure ()
  | _ =>
    removeStaging
    return ← fail s!"{staging} could not be moved to {target}"
  -- 8. Prune.
  let entries :=
    match ← File.list (editorsDirectory order.data) with
    | .ok entries => entries.map (·.name)
    | .error _ => #[]
  for gone in pruned order.data core n names entries order.running do
    discard <| runOf (rootCommand "/bin/rm" #["-rf", gone]) checkPatience
  -- 9. Restart.
  let executable := target ++ "/editor"
  return succeeded executable ((← now) - started)

end Editor.PackageSet
