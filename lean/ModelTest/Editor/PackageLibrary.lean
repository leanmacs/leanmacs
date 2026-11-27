import Editor.PackageLibrary
import Editor.PackageSet.Build
import ModelTest.Check

/-!
# Model tests: `Editor/PackageLibrary.lean`

The model tests of `Editor/PackageLibrary.lean`: `packageLibraryChecks`. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- Each refusal, in the core's order, with the numbers the versioned ones
carry (`editor_package_library::load`). -/
private def refusals : List PackageLibrary.LoadRefusal :=
  [.missing, .notALibrary, .noInit, .runtimeTooSmall, .initFailed, .noDeclaration,
    .newerRuntime 104 88, .otherInterface 2 1]

/-- The checks of how a load of a package's library is read back
(`Editor/PackageLibrary.lean`): status 0 a load, 1 to 8 the eight refusals
in the core's order, 7 and 8 with both of the numbers the load wrote, and a
status past 8 a failed init; each refusal's sentence its own, naming the
package and the library, and for 7 and 8 both versions; and, for each
refusal, that its sentence is what the package-set build's failure line
carries through the build's own judgement of its probe
(`PackageSet.probeFailed`), an initialiser's error as Lean's generated
`main` prints it. -/
def packageLibraryChecks : List Check :=
  let library := "/s/.lake/build/libraries/echo/libecho_service.so"
  let texts := refusals.map (·.describe "echo" library)
  [{    name := "status 0 is a load, with no refusal, whatever the numbers"
        run :=
          pure
            (PackageLibrary.LoadRefusal.of? 0 0 0 == none &&
              PackageLibrary.LoadRefusal.of? 0 7 9 == none) },
      { name :=
          "statuses 1 to 8 are the eight refusals in the core's order, 7 a newer runtime with what it needs and what the editor has, and 8 another interface with the library's and the glue's"
        run :=
          pure
            ([(1, 0, 0), (2, 0, 0), (3, 0, 0), (4, 0, 0), (5, 0, 0), (6, 0, 0), (7, 104, 88),
                    (8, 2, 1)].map
                (fun (status, first, second) =>
                  PackageLibrary.LoadRefusal.of? status first second) ==
              refusals.map some) },
      { name := "a status past 8 is a refusal the load did not expect, read as a failed init"
        run := pure (PackageLibrary.LoadRefusal.of? 9 0 0 == some .initFailed) },
      { name := "each refusal's sentence is distinct"
        run := pure (texts.eraseDups.length == refusals.length) },
      { name := "each refusal's sentence names the package first and the library's path"
        run :=
          pure
            (texts.all fun text =>
              text.startsWith "echo: " && (text.splitOn library).length == 2) },
      { name := "a missing library's sentence says to rebuild the package set"
        run :=
          pure
            ((PackageLibrary.LoadRefusal.missing.describe "echo" library).endsWith
              "rebuild the package set (:reload)") },
      { name :=
          "a library with no declaration says it names neither the runtime nor the interface it was built for"
        run :=
          pure
            (PackageLibrary.LoadRefusal.noDeclaration.describe "echo" library ==
              s!"echo: the library {library} exports no editor_package_declaration, so it says neither the runtime nor the interface it was built for; rebuild it against this editor's package runtime") },
      { name :=
          "a library built for a newer runtime names what it needs and the editor's runtime, both in bytes"
        run :=
          pure
            ((PackageLibrary.LoadRefusal.newerRuntime 104 88).describe "echo" library ==
              s!"echo: the library {library} was built for a newer package runtime than this editor's: it needs 104 bytes of runtime, and this editor's is 88; update the editor, or use a build of echo for this one") },
      { name :=
          "a library of another interface names its version and the one the package's glue expects"
        run :=
          pure
            ((PackageLibrary.LoadRefusal.otherInterface 2 1).describe "echo" library ==
              s!"echo: the library {library} has interface version 2, and this editor's echo expects 1; rebuild the package set so the library and its package match") }] ++
    refusals.map fun refusal =>
      let text := refusal.describe "echo" library
      let probe : Process.Ran :=
        { exit := .code 1, stdout := .empty, stderr := s!"uncaught exception: {text}\n".toUTF8 }
      { name :=
          s!"a probe whose package initialiser threw the refusal {repr refusal} fails the package build with its sentence"
        run :=
          pure
            (PackageSet.probeFailed (.ok probe) ==
              some
                s!"the new editor did not start: it exited with status 1; uncaught exception: {text}") }

/-- The checks of where a package's staged library is found
(`Editor/PackageLibrary.lean`, `staged`): the line for its Lake package in
the libraries record beside the executable, a relative one resolved against
the executable's directory and an absolute one kept, the bundle's in a
bundle; and with no line, or no record, the sentence naming the package,
its Lake package and the record. -/
def packageLibraryStagedChecks : List Check :=
  let entries : List (String × System.FilePath) :=
    [("greeting", "/s/.lake/build/libraries/greeting/libgreeting.so"),
      ("echo", "/s/.lake/build/libraries/echo/libecho_service.so")]
  -- What `staged` answered, the sentence on the left and the path on the
  -- right, and the files it read.
  let staged (appPath : String) (files : List (String × String)) (lake : String) :
    (String ⊕ String) × List String :=
    let (answer, read) :=
      Id.run
        ((PackageLibrary.staged (m := StateM (List String)) appPath
              (fun path => do
                modify (· ++ [path.toString])
                return (files.find? (·.1 == path.toString)).map (·.2))
              "echo" lake).run
          [])
    (match answer with
      | .ok library => .inr library
      | .error sentence => .inl sentence,
      read)
  let built := "/s/.lake/build/bin/editor"
  let installed := "/d/editors/c0ffee/2/editor"
  let bundled := "/Applications/Leanmacs.app/Contents/MacOS/editor"
  let bundleRecord := "/Applications/Leanmacs.app/Contents/Resources/editor.libraries"
  [{  name := "a staged library is the line of its Lake package in the record, and none without one"
      run :=
        pure
          (PackageLibrary.stagedOf? entries "echo" ==
              some "/s/.lake/build/libraries/echo/libecho_service.so" &&
            PackageLibrary.stagedOf? entries "far" == none &&
            PackageLibrary.stagedOf? [] "echo" == none) },
    { name := "a library not staged is said naming the package, its Lake package and the record"
      run :=
        pure
          (PackageLibrary.notStaged "echo" "echo-lake" s!"{built}.libraries" ==
            s!"echo: no library is staged for its Lake package echo-lake beside this editor ({built}.libraries); rebuild the package set (:reload)") },
    { name :=
        "beside a set's editor, the absolute line of the record names the staged library, read through the reader"
      run :=
        pure
          (staged built
              [(s!"{built}.libraries", "echo\t/s/.lake/build/libraries/echo/libecho_service.so\n")]
              "echo" ==
            (.inr "/s/.lake/build/libraries/echo/libecho_service.so", [s!"{built}.libraries"])) },
    { name :=
        "beside an installed editor, the relative line of the record is resolved against the executable's directory, never the working directory"
      run :=
        pure
          (staged installed
              [(s!"{installed}.libraries", "echo\tlibraries/echo/libecho_service.so\n")] "echo" ==
            (.inr "/d/editors/c0ffee/2/libraries/echo/libecho_service.so",
              [s!"{installed}.libraries"])) },
    { name := "in a bundle, the bundle's record is read, and the one beside the executable never"
      run :=
        pure
          (staged bundled
              [(bundleRecord, "echo\tlibraries/echo/libecho_service.so\n"),
                (s!"{bundled}.libraries", "echo\t/elsewhere/libecho_service.so\n")]
              "echo" ==
            (.inr "/Applications/Leanmacs.app/Contents/Resources/libraries/echo/libecho_service.so",
              [bundleRecord])) },
    { name := "with no line for the Lake package, or no record, the sentence names the record read"
      run :=
        pure
          (staged built [(s!"{built}.libraries", "greeting\t/g/libgreeting.so\n")] "echo" ==
              (.inl (PackageLibrary.notStaged "echo" "echo" s!"{built}.libraries"),
                [s!"{built}.libraries"]) &&
            staged bundled [] "echo" ==
              (.inl (PackageLibrary.notStaged "echo" "echo" bundleRecord), [bundleRecord])) }]

end ModelTest
