import Editor.Test.PackageSet
import Editor.Test.Restore
import ModelTest.Check
import ModelTest.Editor.Restore.Restart
import ModelTest.Support.Restore

/-!
# Model tests: `Editor/PackageSet/Build.lean`

The model tests of the package-set build: `packageSetBuildChecks`. The
decision a reload asks (`decide`) is pinned as a pure function; the job
`package-build` and the two commands it posts to on the loop's driver over
the editor's models and the job model, registered by the kit's stand-in
for the build (`Test.PackageSet.buildPackage`, `Editor/Test/PackageSet.lean`),
each command of the build scripted on the process model, the restart of
the kit's stand-in for the `restore` package (`Test.Restore.package`)
registered beside them and the state directory `/state`. So the module
names nothing of the package `package-set`, whose `:package-…` commands
and edit job are checked in that package
(`PackageSetTest.packageSetCommandChecks`, `packages/package-set/`). The root module `ModelTest` runs them; its
module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test
open Editor.PackageSet
open Editor.Test.PackageSet
open RestoreTest

namespace BuildTest

/-- The order a reload of `facts` starts, if it starts one. -/
def orderFor (facts : Facts) : Option Order :=
  match decide (runningWith facts) facts false with
  | .build order => some order
  | _ => none

/-- The command `program --version` the build runs for `order`. -/
def tool (order : Order) (program : String) : Process.Command :=
  toolCommand order program

/-- A streaming command writing `lines` to standard output, then exiting
with `code`. -/
def streaming (command : Process.Command) (lines : Array String) (code : Nat := 0) :
    Process.StreamScript :=
  { command, steps := lines.map fun line => .write .out (line ++ "\n").toUTF8, exit := .code code }

/-- The staging directory of the first build. -/
def staging : String :=
  "/d/editors/staging-1"

/-- The install of `order` into the first staging directory. -/
def install (order : Order) : Process.Command :=
  lakeCommand order #["build", ":editorInstall"] #[("EDITOR_INSTALL_DIR", staging)]

/-- A manifest that resolves `editor-core` to the running editor's own
core, as the root's require by path. -/
def ownManifest : String :=
  "{\"packages\": [{\"type\": \"path\", \"name\": \"«editor-core»\", \"dir\": \"/w/lean\", \"inherited\": false}]}"

/-- The read of the config's manifest, answering `manifest`: once, at the
core check. -/
def manifestRead (manifest : String := ownManifest) : Process.Script :=
  replied (rootCommand "/bin/cat" #["/c/lake-manifest.json"]) 0 manifest

/-- The scripts of a whole build of `order` that succeeds: the manifest's
read (answering `manifest`), the query (listing `crates`), Cargo when
there are crates, the install, the record's read, the probe, the move and
the prune. -/
def succeeding (order : Order) (crates : String := "") (probe : String := "probe: ok\n")
    (manifest : String := ownManifest) : Array Process.Script × Array Process.StreamScript :=
  (#[manifestRead manifest, replied (lakeCommand order #["query", ":editorRustCrates"]) 0 crates,
      replied (tool order "cargo") 0 "cargo 1.98.1",
      replied (rootCommand "/bin/cat" #[staging ++ "/editor.core"]) 0 "c0\n",
      replied (rootCommand (staging ++ "/editor") #["--probe"]) 0 probe,
      replied (rootCommand "/bin/mv" #[staging, "/d/editors/c0/1"]),
      replied (rootCommand "/bin/rm" #["-rf", staging]),
      RestartTest.passing "/d/editors/c0/1/editor"],
    #[streaming (install order) #["Building hello", "Linking editor"]])

/-- The checks' driver, restored, its editor knowing `running`, its
processes as `scripts` and `streams` say, and its config directory `/c`
there. -/
def buildDriver (running : Running) (scripts : Array Process.Script)
    (streams : Array Process.StreamScript := #[]) : Option RestoreDriver :=
  (driverWith (Test.Restore.package.registered.commands ++ buildPackage.registered.commands)
        Test.Restore.package.registered.modes
        (Test.Restore.package.registered.jobs ++ buildPackage.registered.jobs)).map
    fun driver =>
    let driver :=
      { driver with
        loop :=
          { driver.loop with
            state :=
              { driver.loop.state with
                stateDirectory := some stateDirectory, packageSet := running
                launch := RestartTest.launch } }
        jobs :=
          { driver.jobs with
            processes :=
              { driver.jobs.processes with
                scripts, streams }
            files := driver.jobs.files.withDirectory "/c" } }
    begun driver

/-- `driver` once the build of `order` was started and everything settled. -/
def built (driver : RestoreDriver) (order : Order) : RestoreDriver :=
  drained
    (driver.started #[{ name := buildJob, arguments := [.str order.encode], key := some buildJob }])

/-- The lines of the build's buffer. -/
def bufferLines (driver : RestoreDriver) : Array String :=
  ((textNamed driver bufferName).map fun text =>
        (text.splitOn "\n").toArray.filter (!·.isEmpty)).getD
    #[]

/-- The commands started, by their programs and arguments. -/
def startedRuns (driver : RestoreDriver) : Array (String × Array String) :=
  driver.jobs.processes.started.map fun command => (command.program, command.arguments)

/-- Whether `driver`'s last buffer line is a failure starting `how`. -/
def failedWith (driver : RestoreDriver) (how : String) : Bool :=
  ((bufferLines driver).back?.map (·.startsWith s!"Package build failed: {how}")).getD false

end BuildTest

open BuildTest in
/-- The checks of the package-set build (`Editor/PackageSet/Build.lean`). -/
def packageSetBuildChecks : List Check :=
  [{  name :=
        "a reload whose fingerprint matches the running editor's starts no build: the generated lakefile, which requires the running core at its root, the one generated before it did, and one whose manifest differs only in its path entries; a root core naming another directory starts one"
      run :=
        let generatedFacts := lakefileWith
        let oldFacts := setOnlyLakefileWith
        let pathManifest :=
          { generatedFacts with
            manifest := some "{\"packages\": [{\"type\": \"path\", \"name\": \"«default-set»\"}]}" }
        let otherCore :=
          { generatedFacts with
            lakefile :=
              .toml ""
                (generated.extract 0 1 ++
                  #[{ name := "editor-core", source := .path "/elsewhere/lean" }]) }
        pure
          (decide (runningWith generatedFacts) generatedFacts false == .nothing &&
            decide (runningWith oldFacts) oldFacts false == .nothing &&
            decide (runningWith pathManifest) pathManifest false == .nothing &&
            (match decide (runningWith otherCore) otherCore false with
            | .build _ => true
            | _ => false)) },
    { name :=
        "an editor in a bundle, whose shipped fingerprint names its set in Contents/Resources/lean/set, starts no build for the lakefile generated for it; one naming another set directory starts one"
      run :=
        let appPath := "/A.app/Contents/MacOS/editor"
        let bundleSet := "/A.app/Contents/Resources/lean/set"
        let directory : Option String :=
          Id.run (ModuleLookup.setDirectory? appPath (fun _ => pure none) fun _ => pure true)
        let running : Running :=
          Id.run
            (PackageSet.at appPath "/c" (directory.map ("default-set", ·))
              (some "/A.app/Contents/Resources/lean/lean") (some "/t") (some "/d")
              (fun path => pure (if path == coreRecordPath appPath then some "c0\n" else none))
              fun _ => pure true)
        let generatedFor (directory : String) : Facts :=
          {
            lakefile :=
              .toml
                (Config.LakePackage.lakefile
                  { name := "default-set", directory
                    core := "/A.app/Contents/Resources/lean/lean" })
                #[{ name := "default-set", source := .path directory },
                  { name := "editor-core",
                    source := .path "/A.app/Contents/Resources/lean/lean" }] }
        let facts := generatedFor bundleSet
        let elsewhere := generatedFor setDirectory
        pure
          (directory == some bundleSet &&
            Fingerprint.ofFacts running.config facts running.setName running.coreDirectory ==
              running.fingerprint &&
            decide { running with facts } facts false == .nothing &&
            (match decide { running with facts := elsewhere } elsewhere false with
            | .build _ => true
            | _ => false)) },
    { name :=
        "a reload whose fingerprint differs starts one build with its order; none with a build in flight, with no data directory or no core, and with no lake it says so"
      run :=
        let facts := lakefileWith #[hello]
        let running := runningWith facts
        pure
          (orderFor facts ==
              some
                { config := "/c", lake := "/t/bin/lake", data := "/d", running := running.executable
                  environment := #[("LEAN_CC", "/usr/bin/cc")]
                  required := #["path default-set /w/packages", "path hello /h"]
                  set := some "default-set", fetched := #[],
                  resolve := #["default-set", "editor-core", "hello"], core := "/w/lean" } &&
            decide running facts true == .nothing &&
            decide (runningWith facts (data := none)) facts false == .nothing &&
            decide { running with core := none } facts false == .nothing &&
            decide { running with coreDirectory := none } facts false == .nothing &&
            decide (runningWith facts (lake := none)) facts false ==
              .say
                "packages: the package set changed, but this editor has no lake to build it (/t/bin/lake)") },
    { name := "a lakefile.lean starts a build, and an order is carried as text and read back whole"
      run :=
        let facts : Facts := { lakefile := .lean "import Lake" }
        match decide (runningWith facts) facts false, orderFor (lakefileWith #[gitPackage]) with
        | .build _, some order =>
          pure
            (Order.decode? order.encode == some order && order.fetched == #["g"] &&
              order.core == "/w/lean" &&
              (order.encode.splitOn "\ncore /w/lean\n").length == 2)
        | _, _ => pure false },
    { name :=
        "the requires resolved are those missing from the manifest and the git ones whose url or rev the manifest does not hold; a path require whose entry names its directory is not"
      run :=
        let manifest :=
          "{\"packages\": [{\"type\": \"git\", \"name\": \"g\", \"url\": \"https://example.invalid/g\", \"rev\": \"abc\", \"inputRev\": \"v0\"}, {\"type\": \"path\", \"name\": \"«editor-core»\", \"dir\": \"/w/lean\"}, {\"type\": \"path\", \"name\": \"«default-set»\", \"dir\": \"/w/packages\"}]}"
        pure
          (resolveNames (generated ++ #[gitPackage, hello]) (some manifest) == #["g", "hello"] &&
            resolveNames
                (generated ++
                  #[{ gitPackage with
                      source := .git "https://example.invalid/g" (some "v0") none }])
                (some manifest) ==
              #[]) },
    { name :=
        "a path require is resolved when its manifest entry is not a path entry naming the same directory: a git entry, an inherited one at another directory, or a path at another; not when the entry names it spelled another way"
      run :=
        let core : Require := { name := "editor-core", source := .path "/w/lean" }
        let manifestWith (entry : String) : String :=
          "{\"packages\": [" ++ entry ++
            ", {\"type\": \"path\", \"name\": \"«default-set»\", \"dir\": \"/w/packages\"}]}"
        let git :=
          manifestWith
            "{\"type\": \"git\", \"name\": \"«editor-core»\", \"url\": \"file:///r\", \"rev\": \"abc\", \"inputRev\": \"nightly-1\", \"subDir\": \"lean\", \"inherited\": true}"
        let inheritedElsewhere :=
          manifestWith
            "{\"type\": \"path\", \"name\": \"«editor-core»\", \"dir\": \"/elsewhere/lean\", \"inherited\": true}"
        let pathElsewhere :=
          manifestWith
            "{\"type\": \"path\", \"name\": \"«editor-core»\", \"dir\": \"/elsewhere/lean\", \"inherited\": false}"
        let same :=
          manifestWith
            "{\"type\": \"path\", \"name\": \"«editor-core»\", \"dir\": \"/w/packages/../lean\", \"inherited\": true}"
        let required := #[core, { name := "default-set", source := .path "/w/packages" }]
        pure
          (resolveNames required (some git) == #["editor-core"] &&
            resolveNames required (some inheritedElsewhere) == #["editor-core"] &&
            resolveNames required (some pathElsewhere) == #["editor-core"] &&
            resolveNames required (some same) == #[]) },
    { name :=
        "with a git dependency and no git, the build says git is required and how to get it, runs nothing more, and the buffer ends failed; a git that exits 1 is the same"
      run :=
        let facts := lakefileWith #[gitPackage]
        match orderFor facts with
        | none => pure false
        | some order =>
          let check (scripts : Array Process.Script) (how : String)
            (runs : Array (String × Array String)) : Bool :=
            match buildDriver (runningWith facts) scripts with
            | none => false
            | some driver =>
              let done := built driver order
              let echo := done.loop.state.echo
              echo.startsWith "packages: git is required to fetch g, and none works here (" &&
                (echo.splitOn how).length == 2 &&
                echo.endsWith
                  "): install it with `xcode-select --install` on macOS, or from https://git-scm.com, then :reload; this editor keeps running" &&
                startedRuns done == runs &&
                failedWith done "git is required" &&
                (bufferLines done)[0]? == some (header order)
          pure
            (check #[] "cannot start `git`" #[] &&
              check #[replied (tool order "git") 1] "exited with status 1"
                #[("git", #["--version"])]) },
    { name :=
        "a Reservoir dependency is fetched with git: with no git, the build says git is required to fetch it and starts no lake command"
      run :=
        let facts := lakefileWith #[{ name := "b", source := .reservoir "lc" none }]
        match orderFor facts with
        | none => pure false
        | some order =>
          match buildDriver (runningWith facts) #[] with
          | none => pure false
          | some driver =>
            let done := built driver order
            pure
              (order.fetched == #["b"] &&
                done.loop.state.echo.startsWith
                  "packages: git is required to fetch b, and none works here (" &&
                (done.loop.state.echo.splitOn "cannot start `git`").length == 2 &&
                startedRuns done == #[] &&
                !(startedRuns done).any (·.1 == order.lake) &&
                failedWith done "git is required") },
    { name :=
        "with a Rust crate in the set and no Cargo, the build says Cargo is required for that crate and how to get it, and builds nothing; with no crate no Cargo is run"
      run :=
        let facts := lakefileWith #[hello]
        match orderFor facts with
        | none => pure false
        | some order =>
          let query :=
            replied (lakeCommand order #["query", ":editorRustCrates"]) 0
              "echo\techo-service\t/r/echo/rust/Cargo.toml\n"
          let resolve :=
            streaming
              (lakeCommand order
                #["update", "--keep-toolchain", "default-set", "editor-core", "hello"])
              #[]
          match buildDriver (runningWith facts) #[manifestRead, query] #[resolve],
            buildDriver (runningWith facts)
              ((succeeding order).1.filter (·.command.program != "cargo"))
              ((succeeding order).2.push resolve) with
          | some withCrate, some without =>
            let refused := built withCrate order
            let done := built without order
            pure
              (refused.loop.state.echo.startsWith
                  "packages: Cargo is required to build echo's Rust crate echo-service, and none works here (" &&
                !(startedRuns refused).any (·.2.contains ":editorInstall") &&
                !(startedRuns done).any (·.1 == "cargo") &&
                (startedRuns done).any (·.2.contains ":editorInstall"))
          | _, _ => pure false },
    { name :=
        "the resolve runs lake update for the requires the manifest lacks, and a failing build is shown, removes its staging directory, publishes nothing and keeps the editor running"
      run :=
        let facts := lakefileWith #[hello]
        match orderFor facts with
        | none => pure false
        | some order =>
          let resolve :=
            streaming
              (lakeCommand order
                #["update", "--keep-toolchain", "default-set", "editor-core", "hello"])
              #["updated"]
          let failing :=
            streaming (install order) #["error: undefined symbol: leanmacs_no_such_symbol"] 1
          match buildDriver (runningWith facts) (succeeding order).1 #[resolve, failing] with
          | none => pure false
          | some driver =>
            let done := built driver order
            pure
              (done.loop.state.echo ==
                  "packages: lake build exited with status 1; this editor keeps running" &&
                (bufferLines done).contains "updated" &&
                (bufferLines done).contains "error: undefined symbol: leanmacs_no_such_symbol" &&
                failedWith done "lake build exited with status 1" &&
                (startedRuns done).contains ("/bin/rm", #["-rf", staging]) &&
                !(startedRuns done).any (·.1 == "/bin/mv") &&
                done.handOver.isNone) },
    { name :=
        "every command the build runs with the toolchain, git, lake update, lake query, cargo and lake build, has the user's Lean, Lake and compiler variables removed and then the build record set over them, LEAN_CC too when the record holds it"
      run :=
        let facts := lakefileWith #[gitPackage, hello]
        match orderFor facts with
        | none => pure false
        | some order =>
          let resolve :=
            streaming (lakeCommand order (#["update", "--keep-toolchain"] ++ order.resolve)) #[]
          let query :=
            replied (lakeCommand order #["query", ":editorRustCrates"]) 0
              "echo\techo-service\t/r/echo/rust/Cargo.toml\n"
          let (scripts, streams) := succeeding order
          match
            buildDriver (runningWith facts)
              (#[replied (tool order "git") 0 "git version 2.50.0", query] ++ scripts)
              (streams.push resolve) with
          | none => pure false
          | some driver =>
            let done := built driver order
            let tools := done.jobs.processes.started.filter (·.directory.toString == "/c")
            pure
              (tools.map (·.program) ==
                  #["git", "/t/bin/lake", "/t/bin/lake", "cargo", "/t/bin/lake"] &&
                tools.all
                  (fun command =>
                    !command.environment.clear && command.environment.unset == clearedVariables &&
                      command.environment.set.take 1 == #[("LEAN_CC", "/usr/bin/cc")]) &&
                ["LEAN_CC", "LEAN_AR", "LEAN_SYSROOT", "LEAN", "LEAN_PATH", "LEAN_SRC_PATH",
                      "LAKE_HOME", "LAKE_OVERRIDE_LEAN", "ELAN_TOOLCHAIN", "CC", "AR"].all
                  clearedVariables.contains) },
    { name :=
        "a build that fails for want of a header of the system's C library says which tooling is missing and how to get it, in the buffer's failure line and the echo area; a framework or a library the link lacks too; any other line says nothing more"
      run :=
        let facts := lakefileWith #[hello]
        match orderFor facts with
        | none => pure false
        | some order =>
          let resolve :=
            streaming
              (lakeCommand order
                #["update", "--keep-toolchain", "default-set", "editor-core", "hello"])
              #[]
          let failing :=
            streaming (install order) #["c/glue.c:1:10: fatal error: 'stdio.h' file not found"] 1
          match buildDriver (runningWith facts) (succeeding order).1 #[resolve, failing] with
          | none => pure false
          | some driver =>
            let done := built driver order
            let says (text part : String) : Bool := (text.splitOn part).length > 1
            pure
              (failedWith done
                  "lake build exited with status 1: a package's C includes <stdio.h>, a header of the system's C library or SDK" &&
                says done.loop.state.echo "xcode-select --install" &&
                done.loop.state.echo.endsWith "; this editor keeps running" &&
                ((missingTooling? "ld64.lld: error: framework not found for -framework Metal").map
                    (says · "the system framework Metal")) ==
                  some true &&
                ((missingTooling? "ld64.lld: error: library not found for -lsqlite3").map
                    (says · "the system library sqlite3")) ==
                  some true &&
                missingTooling? "ld64.lld: error: undefined symbol: leanmacs_no_such_symbol" ==
                  none) },
    { name :=
        "a bundle's lake killed at its start, or refused, as macOS refuses a quarantined tool, ends the build saying macOS refused the bundled toolchain and how to remove the flag; a lake outside a bundle, or another failure, says what it said before"
      run :=
        let facts := lakefileWith #[hello]
        let bundled := "/Applications/Leanmacs.app/Contents/Resources/lean/toolchain/bin/lake"
        match decide (runningWith facts (lake := some bundled)) facts false with
        | .build order =>
          let resolve :=
            { command :=
                lakeCommand order
                  #["update", "--keep-toolchain", "default-set", "editor-core", "hello"]
              steps := #[], exit := .signal 9 : Process.StreamScript }
          match buildDriver (runningWith facts (lake := some bundled)) #[] #[resolve] with
          | none => pure false
          | some driver =>
            let done := built driver order
            pure
              (done.loop.state.echo ==
                  s!"packages: macOS refused to run the bundled toolchain ({bundled}); remove the quarantine flag: xattr -dr com.apple.quarantine /Applications/Leanmacs.app; this editor keeps running" &&
                refusedToolchain? bundled "could not start: Operation not permitted" ==
                  some
                    s!"macOS refused to run the bundled toolchain ({bundled}); remove the quarantine flag: xattr -dr com.apple.quarantine /Applications/Leanmacs.app" &&
                refusedToolchain? "/t/bin/lake" "was ended by the signal 9" == none &&
                refusedToolchain? bundled "exited with status 1" == none)
        | _ => pure false },
    { name :=
        "macOS refusing the bundle's lake at lake query :editorRustCrates, which cannot start or is killed, or at lake build :editorInstall, killed, ends the build saying so and how to remove the flag, and nothing else"
      run :=
        let facts := lakefileWith #[hello]
        let bundled := "/Applications/Leanmacs.app/Contents/Resources/lean/toolchain/bin/lake"
        let running := runningWith facts (lake := some bundled)
        match decide running facts false with
        | .build order =>
          let refusal :=
            s!"macOS refused to run the bundled toolchain ({bundled}); remove the quarantine flag: xattr -dr com.apple.quarantine /Applications/Leanmacs.app"
          let resolve :=
            streaming
              (lakeCommand order
                #["update", "--keep-toolchain", "default-set", "editor-core", "hello"])
              #[]
          let query := lakeCommand order #["query", ":editorRustCrates"]
          let (scripts, streams) := succeeding order
          let others := scripts.filter (·.command != query)
          let refusedWith (scripts : Array Process.Script) (streams : Array Process.StreamScript) :
            Bool :=
            match buildDriver running scripts streams with
            | none => false
            | some driver =>
              let done := built driver order
              done.loop.state.echo == s!"packages: {refusal}; this editor keeps running" &&
                ((bufferLines done).back?.map
                    (·.startsWith s!"Package build failed: {refusal} after ")) ==
                  some true &&
                !(startedRuns done).any (·.1 == "/bin/mv")
          pure
            (refusedWith scripts
                (#[resolve,
                  { command := install order, steps := #[], exit := .signal 9 :
                    Process.StreamScript }]) &&
              refusedWith
                (others.push
                  { command := query, reply := .error (.denied "Operation not permitted") })
                (streams.push resolve) &&
              refusedWith
                (others.push
                  { command := query
                    reply := .ok { exit := .signal 9, stdout := .empty, stderr := .empty } })
                (streams.push resolve))
        | _ => pure false },
    { name :=
        "how a step running lake failed is decided once: macOS refusing a bundle's lake is said as it is at every step, and any other end after the step"
      run :=
        let bundled := "/Applications/Leanmacs.app/Contents/Resources/lean/toolchain/bin/lake"
        let killed := Ended.describe (.signal 9)
        let refusal := (refusedToolchain? bundled killed).getD ""
        pure
          (LakeFailure.of bundled killed == .refused refusal &&
            LakeFailure.of bundled "could not start: Operation not permitted" ==
              .refused ((refusedToolchain? bundled "Operation not permitted").getD "") &&
            LakeFailure.of "/t/bin/lake" killed == .ended killed &&
            LakeFailure.of bundled "exited with status 1" == .ended "exited with status 1" &&
            (LakeFailure.refused refusal).describe "lake build" == refusal &&
            (LakeFailure.refused refusal).describe "lake update" == refusal &&
            (LakeFailure.ended "exited with status 1").describe "lake build" ==
              "lake build exited with status 1") },
    { name :=
        "a manifest whose editor-core is git, a path at another directory, or missing ends the build after lake update, before lake query and lake build, makes no staging directory, and says why and how to fix it; the set's inherited entry for the running core, spelled <set>/../lean, passes"
      run :=
        let facts := lakefileWith #[hello]
        match orderFor facts with
        | none => pure false
        | some order =>
          let resolve :=
            streaming
              (lakeCommand order
                #["update", "--keep-toolchain", "default-set", "editor-core", "hello"])
              #[]
          let fix :=
            "not this editor's core /w/lean; require it at the root of /c/lakefile.toml with path = \"/w/lean\", as its last require, after every other (:package-install and :package-remove write it), then :reload"
          let refused (manifest : String) (what : String) : Bool :=
            match buildDriver (runningWith facts) #[manifestRead manifest] #[resolve] with
            | none => false
            | some driver =>
              let done := built driver order
              let how := s!"the package set resolves editor-core to {what}, {fix}"
              done.loop.state.echo == s!"packages: {how}; this editor keeps running" &&
                failedWith done how &&
                !(startedRuns done).any (·.2.contains "query") &&
                !(startedRuns done).any (·.2.contains ":editorInstall") &&
                (startedRuns done).any (·.2.contains "update") &&
                !done.jobs.files.directories.any (·.toString == "/d/editors")
          let git :=
            "{\"packages\": [{\"type\": \"git\", \"name\": \"«editor-core»\", \"url\": \"file:///r\", \"rev\": \"abc\", \"inputRev\": \"nightly-1\", \"subDir\": \"lean\", \"inherited\": true}]}"
          let elsewhere :=
            "{\"packages\": [{\"type\": \"path\", \"name\": \"«editor-core»\", \"dir\": \"/elsewhere/lean\", \"inherited\": false}]}"
          let inherited :=
            "{\"packages\": [{\"type\": \"path\", \"name\": \"«editor-core»\", \"dir\": \"/w/packages/../lean\", \"inherited\": true}]}"
          let (scripts, streams) := succeeding order (manifest := inherited)
          let passes :=
            match buildDriver (runningWith facts) scripts (streams.push resolve) with
            | none => false
            | some driver =>
              ((bufferLines (built driver order)).back?.map
                  (·.startsWith "Package build finished after")) ==
                some true
          pure
            (refused git "git file:///r at abc" &&
              refused elsewhere "the directory /elsewhere/lean" &&
              refused "{\"packages\": []}" "nothing" &&
              passes) },
    { name :=
        "the core check resolves a relative editor-core entry against the config directory, as the fingerprint and the edits do: ../lean from /w/x is the running core at /w/lean and passes, lean is refused"
      run :=
        let entry (directory : String) : String :=
          s!"\{\"packages\": [\{\"type\": \"path\", \"name\": \"«editor-core»\", \"dir\": \"{directory}\", \"inherited\": false}]}"
        pure
          (coreRefusal? "/w/x" "/w/lean" (some (entry "../lean")) == none &&
            ((coreRefusal? "/w/x" "/w/lean" (some (entry "lean"))).map
                (·.startsWith
                  "the package set resolves editor-core to the directory /w/x/lean,")) ==
              some true) },
    { name := "a probe that fails removes the staging directory and publishes nothing"
      run :=
        let facts := lakefileWith #[hello]
        match orderFor facts with
        | none => pure false
        | some order =>
          let resolve :=
            streaming
              (lakeCommand order
                #["update", "--keep-toolchain", "default-set", "editor-core", "hello"])
              #[]
          let (scripts, streams) := succeeding order (probe := "dyld: no\n")
          match buildDriver (runningWith facts) scripts (streams.push resolve) with
          | none => pure false
          | some driver =>
            let done := built driver order
            pure
              (failedWith done "the new editor did not start" &&
                (startedRuns done).contains ("/bin/rm", #["-rf", staging]) &&
                !(startedRuns done).any (·.1 == "/bin/mv")) },
    { name :=
        "a build that succeeds writes the record, publishes version 1 of its core, ends the buffer finished and restarts into it"
      run :=
        let facts := lakefileWith #[hello]
        match orderFor facts with
        | none => pure false
        | some order =>
          let resolve :=
            streaming
              (lakeCommand order
                #["update", "--keep-toolchain", "default-set", "editor-core", "hello"])
              #[]
          let (scripts, streams) := succeeding order
          match buildDriver (runningWith facts) scripts (streams.push resolve) with
          | none => pure false
          | some driver =>
            let done := built driver order
            let record : Fingerprint :=
              { required := order.required, pins := #[], set := some "default-set" }
            pure
              ((bufferLines done).back?.map (·.startsWith "Package build finished after") ==
                  some true &&
                (bufferLines done).contains "Linking editor" &&
                (startedRuns done).contains ("/bin/mv", #[staging, "/d/editors/c0/1"]) &&
                bytesAt done (staging ++ "/editor.packages") == some record.text.toUTF8 &&
                (done.handOver.map (·.handover.candidates.toList.head?)) ==
                  some (some (System.FilePath.mk "/d/editors/c0/1/editor"))) },
    { name :=
        "pruning keeps the version before the new one and the running editor's core, and removes older versions, other cores and staging directories"
      run :=
        pure
          (pruned "/d" "c1" 3 #["1", "2", "3", "x"] #["c1", "c0", "cold", "staging-4"]
                "/d/editors/c0/5/editor" ==
              #["/d/editors/c1/1", "/d/editors/cold", "/d/editors/staging-4"] &&
            nextVersion #["1", "2", "10", "staging", "x"] == 11 &&
            nextStaging #["staging-1", "staging-x", "3"] == 2) },
    { name :=
        "pruning never removes the version the running editor is under: an older version of the build's own core, or the one before the new one"
      run :=
        pure
          (pruned "/d" "c1" 3 #["1", "2", "3"] #["c1"] "/d/editors/c1/1/editor" == #[] &&
            pruned "/d" "c1" 4 #["1", "2", "3", "4"] #["c1"] "/d/editors/c1/1/editor" ==
              #["/d/editors/c1/2"] &&
            pruned "/d" "c1" 4 #["1", "2", "3", "4"] #["c1"] "/d/editors/c1/3/editor" ==
              #["/d/editors/c1/1", "/d/editors/c1/2"] &&
            pruned "/d" "c1" 13 #["1", "11", "12", "13"] #["c1"] "/d/editors/c1/1/editor" ==
              #["/d/editors/c1/11"]) }]

end ModelTest
