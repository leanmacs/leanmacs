import Editor.Test.Hosted
import Editor.Test.PackageSet
import PackageSet.Compiled
import PackageSetTest.Check

/-!
# The tests of `PackageSet/Compiled.lean`

The tests of the `package-set` package's commands and of what it
registers:
`packageSetCommandChecks`. `:package-install`, `:package-remove` and
`:package-update` and the edit job they start run on the kit's hosted
driver (`Editor/Test/Hosted.lean`) over the package itself, as a host
installs it, the lakefile's read and the move scripted on the process
model; the install's forms are pinned as a pure function. The build the
commands start is the core's and is checked where it lives
(`ModelTest.packageSetBuildChecks`, in the core); these hold only that it
is started, and that the package registers it as the kit's stand-in does
(`Editor.Test.PackageSet.buildPackage`). The test driver
`PackageSetTest/Model.lean` runs them; its module doc says what each
shows.
-/

namespace PackageSetTest

open Editor
open Editor.Test
open Editor.PackageSet
open Editor.Test.PackageSet

namespace PackageSetCommandTest

/-- The checks' driver: the package `package-set` hosted, its editor
knowing `running`, its processes as `scripts` say, and its config directory
`/c` there. -/
def commandDriver (running : Running) (scripts : Array Process.Script) : Option TestDriver :=
  (hostedDriver #[PackageSet.package]).map fun driver =>
    { driver with
      loop := { driver.loop with state := { driver.loop.state with packageSet := running } }
      jobs :=
        { driver.jobs with
          processes := { driver.jobs.processes with scripts }
          files := driver.jobs.files.withDirectory "/c" } }

/-- `driver` once `command` is invoked with `arguments`. -/
def invoked (driver : TestDriver) (command : String) (arguments : List Argument := []) :
    TestDriver :=
  (driver.stepped (driver.loop.invoke driver.handed { command, arguments })).1

/-- `driver` once every job it holds, and those their commands start, is
finished (`hostedSettled`). -/
def drained (driver : TestDriver) : TestDriver :=
  hostedSettled driver

/-- The bytes of the file at `path` in `driver`'s world. -/
def bytesAt (driver : TestDriver) (path : System.FilePath) : Option ByteArray :=
  (driver.jobs.files.file? path).map (·.bytes)

/-- Two answers of the install's parse are equal when both are the same
require or the same refusal. -/
instance : BEq (Except String Require) where
  beq
    | .ok one, .ok other => one == other
    | .error one, .error other => one == other
    | _, _ => false

end PackageSetCommandTest

open PackageSetCommandTest in
/-- The checks of the `package-set` package's commands
(`PackageSet/Compiled.lean`). -/
def packageSetCommandChecks : List Check :=
  [{  name :=
        ":package-install edits the lakefile through the edit job, which writes it and asks for a reload; a lakefile.lean is refused"
      run :=
        let facts := lakefileWith
        let text :=
          match facts.lakefile with
          | .toml text _ => text
          | _ => ""
        let edited :=
          (withCoreEdit "/c" (some coreDirectory) text generated (install · · hello)).toOption.getD
            ""
        let cat := replied (rootCommand "/bin/cat" #["/c/lakefile.toml"]) 0 text
        let mv :=
          replied (rootCommand "/bin/mv" #["/c/lakefile.toml.leanmacs-edit", "/c/lakefile.toml"])
        match commandDriver (runningWith facts) #[cat, mv],
          commandDriver (runningWith { lakefile := .lean "x" }) #[] with
        | some driver, some leanDriver =>
          let done := drained (invoked driver installName [.str "hello /h"])
          let refused := drained (invoked leanDriver installName [.str "hello /h"])
          pure
            (done.reloads == driver.reloads + 1 &&
              done.loop.state.echo == s!"{installName}: added hello; reloading" &&
              bytesAt done "/c/lakefile.toml.leanmacs-edit" == some edited.toUTF8 &&
              refused.loop.state.echo ==
                s!"{installName}: this config's lakefile is a lakefile.lean, and the package commands edit lakefile.toml only")
        | _, _ => pure false },
    { name :=
        ":package-install, :package-remove and :package-update with a rev, on the lakefile generated before the core was required at its root, each start the edit job with the text repaired: the running core's require last"
      run :=
        let facts := setOnlyLakefileWith #[gitPackage]
        let (text, required) :=
          match facts.lakefile with
          | .toml text required => (text, required)
          | _ => ("", #[])
        let cat := replied (rootCommand "/bin/cat" #["/c/lakefile.toml"]) 0 text
        let mv :=
          replied (rootCommand "/bin/mv" #["/c/lakefile.toml.leanmacs-edit", "/c/lakefile.toml"])
        let repaired (edit : String → Array Require → Except String String) : Option ByteArray :=
          (withCoreEdit "/c" (some coreDirectory) text required edit).toOption.map (·.toUTF8)
        let lastIsCore (bytes : Option ByteArray) : Bool :=
          match bytes.bind (String.fromUTF8? ·) with
          | some edited =>
            (edited.splitOn "name = \"editor-core\"").length == 2 &&
              (edited.splitOn "[[require]]").getLast?.map
                  (·.startsWith "\nname = \"editor-core\"\npath = \"/w/lean\"\n") ==
                some true
          | none => false
        let after (name : String) (argument : String) : Option ByteArray :=
          (commandDriver (runningWith facts) #[cat, mv]).bind fun driver =>
            bytesAt (drained (invoked driver name [.str argument])) "/c/lakefile.toml.leanmacs-edit"
        let installed := after installName "hello /h"
        let removed := after removeName "compile"
        let revised := after updateName "g v2"
        pure
          (installed == repaired (install · · hello) && lastIsCore installed &&
            removed ==
              repaired (remove · · "compile" "/c" (some "default-set") facts.setRequires) &&
            lastIsCore removed &&
            revised == repaired (setRev · · "g" "v2") &&
            lastIsCore revised) },
    { name :=
        "an editor that knows no directory of its core refuses an edit, saying so, and writes nothing"
      run :=
        let facts := setOnlyLakefileWith
        match commandDriver { runningWith facts with coreDirectory := none } #[] with
        | some driver =>
          let done := drained (invoked driver installName [.str "hello /h"])
          pure
            (done.reloads == driver.reloads &&
              done.loop.state.echo ==
                s!"{installName}: this editor knows no directory of its core, so it cannot write the lakefile's editor-core require")
        | none => pure false },
    { name :=
        "an edit of a lakefile that changed since the last reload is refused, and nothing is written or reloaded"
      run :=
        let facts := lakefileWith
        let cat := replied (rootCommand "/bin/cat" #["/c/lakefile.toml"]) 0 "edited by hand\n"
        match commandDriver (runningWith facts) #[cat] with
        | some driver =>
          let done := drained (invoked driver removeName [.str "compile"])
          pure
            (done.reloads == driver.reloads &&
              done.loop.state.echo ==
                s!"{removeName}: the lakefile changed since the last reload; :reload and try again")
        | none => pure false },
    { name :=
        ":package-update and :package-update <name>, on the lakefile generated before the core was required at its root, start the edit job with the text repaired, the running core's require last, and no build; on a repaired one they start the build, with no edit"
      run :=
        let facts := setOnlyLakefileWith #[gitPackage]
        let (text, required) :=
          match facts.lakefile with
          | .toml text required => (text, required)
          | _ => ("", #[])
        let cat := replied (rootCommand "/bin/cat" #["/c/lakefile.toml"]) 0 text
        let mv :=
          replied (rootCommand "/bin/mv" #["/c/lakefile.toml.leanmacs-edit", "/c/lakefile.toml"])
        let repaired :=
          (withCoreEdit "/c" (some coreDirectory) text required fun text _ => .ok text).toOption.map
            (·.toUTF8)
        let repairs (argument : String) : Bool :=
          match commandDriver (runningWith facts) #[cat, mv] with
          | some driver =>
            let updating := invoked driver updateName [.str argument]
            let done := drained updating
            repaired != some text.toUTF8 &&
              bytesAt done "/c/lakefile.toml.leanmacs-edit" == repaired &&
              done.reloads == driver.reloads + 1 &&
              done.loop.state.echo ==
                s!"{updateName}: wrote the core's require at the root of the lakefile; :{updateName} again to update; reloading" &&
              !updating.startedJobs.contains (buildJob, some buildJob)
          | none => false
        let builds (argument : String) : Bool :=
          match commandDriver (runningWith (repairedLakefileWith #[gitPackage])) #[] with
          | some driver =>
            let updating := invoked driver updateName [.str argument]
            updating.startedJobs.contains (buildJob, some buildJob) &&
              !updating.startedJobs.contains (editJob, some editJob) &&
              updating.loop.state.echo == startedLine &&
              updating.reloads == driver.reloads
          | none => false
        pure (repairs "" && repairs "g" && builds "" && builds "g") },
    { name :=
        ":package-update with a rev edits the require's rev; with none it starts the build resolving every git package, with no edit"
      run :=
        let facts := repairedLakefileWith #[gitPackage]
        let (text, required) :=
          match facts.lakefile with
          | .toml text required => (text, required)
          | _ => ("", #[])
        let cat := replied (rootCommand "/bin/cat" #["/c/lakefile.toml"]) 0 text
        let mv :=
          replied (rootCommand "/bin/mv" #["/c/lakefile.toml.leanmacs-edit", "/c/lakefile.toml"])
        match commandDriver (runningWith facts) #[cat, mv] with
        | some driver =>
          let revised := drained (invoked driver updateName [.str "g v2"])
          let updating := invoked driver updateName [.str ""]
          let order := updating.startedJobs.contains (buildJob, some buildJob)
          pure
            (revised.reloads == driver.reloads + 1 &&
              bytesAt revised "/c/lakefile.toml.leanmacs-edit" ==
                ((withCoreEdit "/c" (some coreDirectory) text required
                      (setRev · · "g" "v2")).toOption.map
                  (·.toUTF8)) &&
              order &&
              updating.loop.state.echo == startedLine &&
              updating.reloads == driver.reloads)
        | none => pure false },
    { name :=
        "the install's forms: a path, a git url with a rev, and scope/name with a version; anything else says what it takes"
      run :=
        pure
          (requireOf none ["a", "/p"] == .ok { name := "a", source := .path "/p" } &&
            requireOf (some "/home/ada") ["a", "~/p"] ==
              .ok { name := "a", source := .path "/home/ada/p" } &&
            requireOf none ["g", "https://h/g", "v1"] ==
              .ok { name := "g", source := .git "https://h/g" (some "v1") none } &&
            requireOf none ["lc/batteries", "v4"] ==
              .ok { name := "batteries", source := .reservoir "lc" (some "v4") } &&
            requireOf none ["a"] == .error installUsage) },
    { name :=
        "the package registers the job and the two commands the kit's stand-in for the build does, the build reported, and its own edit job and three commands with their ex names, each taking text; it keeps no store across a restart and leaves no job to its owner to start again"
      run :=
        let registered := PackageSet.package.registered
        let standIn := buildPackage.registered
        let registry := hostedRegistry #[PackageSet.package]
        pure
          (PackageSet.package.name == "package-set" &&
            standIn.jobs.map (fun job => (job.name, job.reported, job.restarted)) ==
              #[(buildJob, true, false)] &&
            registered.jobs.map (fun job => (job.name, job.reported, job.restarted)) ==
              #[(buildJob, true, false), (editJob, false, false)] &&
            standIn.commands.map (·.name) == #[startedName, outputName] &&
            registered.commands.map (·.name) ==
              #[installName, removeName, updateName, startedName, outputName] &&
            registered.ex.map (fun binding => (binding.name, binding.command, binding.takes)) ==
              #[("package-install", "package-install", .text),
                ("package-remove", "package-remove", .text),
                ("package-update", "package-update", .text)] &&
            (registry.jobs.filter (·.registration.reported)).map (·.registration.name) ==
              #["package-build"] &&
            (registry.jobs.filter (·.registration.restarted)).isEmpty &&
            registry.codecs.isEmpty) }]

end PackageSetTest
