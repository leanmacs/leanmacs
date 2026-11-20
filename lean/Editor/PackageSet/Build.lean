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
the host asks after each reload), and so does `:package-update`
(`Editor/PackageSet/Compiled.lean`). It runs over the job port's process
and file requests alone, so every decision it makes is pinned on the job
and process models (`ModelTest.packageSetBuildChecks`), the exact commands,
arguments and environments among them.

## When a reload starts it (`decide`)

None is started when a build is in flight, when the config has no
lakefile that can be read, when the running editor knows no fingerprint of
its own, no data directory or no core identity, or when the fingerprints
are the same (`same`). With no `lake` it starts none and says
`packages: the package set changed, but this editor has no lake to build
it (<sysroot>/bin/lake)`. Otherwise it starts one with an order (`Order`):
the config directory, the `lake`, the data directory, the running
executable, the build environment (`editor.build`), the requires'
lines for the record, the shipped set's name, the requires fetched with
git, and the requires to resolve (`resolveNames`).

## The steps, in order

1. **Git**, when the lakefile directly names a git or Reservoir
   dependency: `git --version`. Not found, or a non-zero exit (macOS's
   command-line-tools shim), stops the build with `gitRequired`.
2. **Resolve**: `lake update --keep-toolchain <names>` for the requires
   missing from the manifest or whose entry disagrees with the lakefile's
   url or rev; for `:package-update`, the named package, or every git and
   Reservoir require.
3. **Rust**: `lake query :editorRustCrates`, then, when the set holds a
   package with a Rust crate, `cargo --version`. A set with no crate needs
   no Cargo: its link reuses the core's archive as it is built
   (`rustSource` in `lean/lakefile.lean`; the editor never ships Cargo,
   decided 2026-11-20). One with a crate needs the user's own, and a
   missing or broken one stops the build with `cargoRequired`, naming the
   package's crate.
4. **Build and install**: `lake build :editorInstall` with
   `EDITOR_INSTALL_DIR=<data>/editors/staging-<k>` (`nextStaging`) and the build
   environment, its output streamed into the build buffer.
5. **Record**: the new editor's `editor.core` is read, and
   `editor.packages` written beside it: the requires, the pins read again
   from the manifest after the resolve, and the set's name.
6. **Probe**: `<staging>/editor --probe`, within 10 s, must print `probe:
   ok`, which catches a bad link, a bad signature or an `initialize` that
   throws before anything is published.
7. **Publish**: `/bin/mv <staging> <data>/editors/<core>/<n>`.
8. **Prune**: `/bin/rm -rf` for each directory `pruned` names.
9. **Restart** into the new editor (`Editor.restart`), or, with no state
   directory, `packages: built <exe>; it starts at the next launch`.

Every command of the build runs in the config directory with the editor's
own environment and the build environment set over it, the probe and the
file moves from `/`. **Every failure** removes the staging directory, ends
the buffer with `Package build failed: <how> after <t>`, says `packages:
<how>; this editor keeps running` and publishes nothing.

## The buffer

`*package-build*` (`bufferName`) is made read-only by the job's first post
(`startedName`), its text replaced by a header line, and shown through the
display rules for the opener `package-build`; output is appended as it
arrives, batched as the compile mode's is (`batchPause`), and the job's
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

/-- How long the job pauses after each post of output, in milliseconds. -/
def batchPause : Nat :=
  50

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
      order.resolve.map ("resolve " ++ ·)
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
      fetched := all "fetched", resolve := all "resolve" }

/-- The requires to resolve with `lake update`: those whose name the
manifest holds no entry of, and the git ones whose entry has another url,
or another revision than the lakefile asks for. -/
def resolveNames (required : Array Require) (manifest : Option String) : Array String :=
  let entries :=
    match manifest.map (Json.parse ·.toUTF8) with
    | some (.ok document) =>
      match document.field? "packages" with
      | some (.array items) =>
        items.filterMap fun (item : Json.Value) =>
          match item.field? "name" with
          | some (.string name) => some (unquoted name)
          | _ => none
      | _ => #[]
    | _ => #[]
  let pinned := (manifest.map gitEntries).getD #[]
  (required.filter fun require =>
        if !entries.contains require.name then true
        else
          match require.source, pinned.find? (·.name == require.name) with
          | .git url rev _, some pin => pin.url != url || (rev.isSome && pin.inputRev != rev)
          | _, _ => false).map
    (·.name)

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
  let some fingerprint := Fingerprint.ofFacts running.config facts running.setName | throw ""
  let some data := running.data | throw ""
  let some _ := running.core | throw ""
  let some lake := running.lake | throw (noLake running)
  let required :=
    match facts.lakefile with
    | .toml _ required => required
    | _ => #[]
  let fetched := (required.filter (·.source.fetched)).map (·.name)
  return {
      config := running.config, lake, data, running := running.executable
      environment := running.build, required := fingerprint.required, set := running.setName
      fetched, resolve := resolve.getD (resolveNames required facts.manifest) }

/-- What a reload is to do about the package set, given what the running
editor knows of its own (`running`), what the reload read (`facts`) and
whether a build is in flight ("When a reload starts it", in the module
docs). -/
def decide (running : Running) (facts : Facts) (inFlight : Bool) : Decision :=
  if inFlight then .nothing
  else
    match running.fingerprint, Fingerprint.ofFacts running.config facts running.setName with
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

/-- The build environment of `order`, over the editor's own. -/
def Order.environmentOf (order : Order) (more : Array (String × String) := #[]) :
    Process.Environment :=
  { set := order.environment ++ more }

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
as they come: none when it exits 0, else how it ended. -/
def streamed (command : Process.Command) : JobM (Option String) := do
  match
    ←
      Process.request
          (.start command { stdout := .lines, stderr := .lines, bound := lineBound }) with
  | .error error =>
    return some error.describe
  | .ok child =>
    for _ in [0:1000000000] do
      match ← Process.read child with
      | .error error =>
        return some error.describe
      | .ok delivery =>
        let lines := framesOf delivery.stdout ++ framesOf delivery.stderr
        unless lines.isEmpty do
          post { command := outputName, arguments := lines.toList.map .str }
        match delivery.ended with
        | some (.exited (.code 0)) =>
          return none
        | some (.exited exit) =>
          return some (Ended.describe exit)
        | some (.lineTooLong _ bound) =>
          return some s!"wrote a line longer than {bound} bytes"
        | some (.failed detail) =>
          return some detail
        | none =>
          sleep batchPause
    return some "it never ended"

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
    if let some how←
        streamed (lakeCommand order (#["update", "--keep-toolchain"] ++ order.resolve)) then
      return ← fail s!"lake update {how}"
  -- 3. Rust: the set's crates, then Cargo, which every link runs.
  let crates ←
    match ← runOf (lakeCommand order #["query", ":editorRustCrates"]) queryPatience with
    | .error how =>
      return ← fail s!"lake query :editorRustCrates could not run: {how}"
    | .ok ran =>
      match ran.exit with
      | .code 0 =>
        pure (cratesIn ((String.fromUTF8? ran.stdout).getD ""))
      | exit =>
        let said := ((String.fromUTF8? ran.stderr).getD "").splitOn "\n" |>.filter (!·.isEmpty)
        post { command := outputName, arguments := said.map .str }
        return ← fail s!"lake query :editorRustCrates {Ended.describe exit}"
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
  if let some how←
      streamed
        (lakeCommand order #["build", ":editorInstall"] #[("EDITOR_INSTALL_DIR", staging)]) then
    removeStaging
    return ← fail s!"lake build {how}"
  -- 5. The new editor's core, and its record.
  let some core := (← readText (staging ++ "/editor.core")).bind coreIn
    |
    removeStaging
    return ← fail s!"the build wrote no {staging}/editor.core"
  let manifest ← readText (order.config ++ "/lake-manifest.json")
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
  let probeHow :=
    match probe with
    | .error error => some error.describe
    | .ok ran => Restore.probeFailure ran
  if let some how := probeHow then
    removeStaging
    return ← fail s!"the new editor did not start: {how}"
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
