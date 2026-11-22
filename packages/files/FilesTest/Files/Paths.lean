import Editor.Command
import Editor.Completion
import Editor.Completion.Candidate
import Editor.Completion.Later
import Editor.File.Model
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Program
import Editor.Scene
import Editor.Test.Sources
import Editor.Text
import Editor.Text.Model
import Files.Paths
import FilesTest.Check

/-!
# Model tests: `Files/Paths.lean`

The model tests of `Files/Paths.lean`: `pathsChecks`, the
last of which are the completion sources' contract over the file source. The test
driver's root, `FilesTest/Model.lean`, runs them; its module doc says
what each shows.
-/

namespace FilesTest

open Editor

/-- The files of the path checks: `/w` holds `b.txt`, `A.txt`, `.hidden`,
and the directories `src` and `.git`; `/w/locked` is a directory too. -/
def pathsFiles : FileModel :=
  ((((((({} : FileModel).withDirectory "/w").withFile "/w/b.txt" "b".toUTF8).withFile "/w/A.txt"
                    "a".toUTF8).withFile
                "/w/.hidden" "h".toUTF8).withDirectory
            "/w/src").withDirectory
        "/w/.git").withDirectory
    "/w/locked"

/-- What the file source's job delivers for `text`, read under `place`, over
`files`, on the job model: its batches, decoded from its posts, and how it
ended. -/
def gatheredPaths (text : String) (files : FileModel := pathsFiles)
    (place : Completion.Place := { directory := some "/w" }) :
    Job.Outcome Unit × Array (Array Completion.Candidate) :=
  let order : Completion.Order :=
    { view := ⟨3⟩, index := 0, generation := 1, query := { text, view := ⟨0⟩, place } }
  let (outcome, model) :=
    (Completion.answering Completion.Paths.gather order.arguments ()).runModel { files }
  (match outcome with
    | .finished _ => .finished ()
    | .failed message => .failed message
    | .cancelled => .cancelled,
    model.posted.filterMap fun posted =>
      (Completion.batchOfArguments? posted.arguments).map fun (_, _, _, batch) => batch)

/-- Why the file source's job refused `text`, read under `place`, over
`files`: what it threw, or `none` when it did not. -/
def pathsRefusal (text : String) (files : FileModel := pathsFiles)
    (place : Completion.Place := { directory := some "/w" }) : Option String :=
  let job : JobM String := do
    try
      Completion.Paths.gather { text, view := ⟨0⟩, place } fun _ => pure ()
      return ""
    catch message =>
      return message
  match (job.runModel { files }).1 with
  | .finished "" => none
  | .finished message => some message
  | _ => none

/-- The checks of the file source (`Files/Paths.lean`) on the job
model. -/
def pathsChecks : List Check :=
  [{    name :=
          "the file source lists a directory's entries directories first, by name ignoring case, a directory with a trailing /, its name and a / as its label, annotated directory, of the kind directory and partial; a file of the kind file; a name that starts with . hidden until a . is typed"
        run :=
          pure <|
            let (outcome, batches) := gatheredPaths "/w/"
            let all := batches.flatten
            (outcome matches .finished ()) && batches.size == 1 &&
              all.map (·.text) ==
                #["/w/.git/", "/w/locked/", "/w/src/", "/w/.hidden", "/w/A.txt", "/w/b.txt"] &&
              all.map (·.label) ==
                #[some ".git/", some "locked/", some "src/", some ".hidden", some "A.txt",
                  some "b.txt"] &&
              all.map (·.hiddenUntil) == #[some ".", none, none, some ".", none, none] &&
              all.map (·.isPartial) == #[true, true, true, false, false, false] &&
              all.map (·.kind) ==
                #[some "directory", some "directory", some "directory", some "file", some "file",
                  some "file"] &&
              all.map (·.annotation) ==
                #[some "directory", some "directory", some "directory", none, none, none] },
      { name :=
          "the texts are written under the tidied directory: /x//w/ lists /w/'s entries as /w/…"
        run :=
          pure <|
            let (_, batches) := gatheredPaths "/x//w/"
            (batches.flatten.map (·.text))[0]? == some "/w/.git/" },
      { name := "2,500 entries come in three batches of at most 1,000, in order"
        run :=
          pure <|
            let names := (Array.range 2500).map fun index => s!"f{1000000 + index}"
            let files :=
              names.foldl
                (fun (model : FileModel) (name : String) => model.withFile ("/big" / name) .empty)
                (({} : FileModel).withDirectory "/big")
            let (_, batches) := gatheredPaths "/big/" files
            batches.map (·.size) == #[1000, 1000, 500] &&
              batches.flatten.map (·.text) == names.map ("/big/" ++ ·) },
      { name :=
          "an unreadable directory, a missing one, a file, a ~ with no home and a relative text with no directory each throw cannot list <shown>: <why>"
        run :=
          pure <|
            let locked := { pathsFiles with unreadable := #["/w/locked"] }
            pathsRefusal "/w/locked/" locked ==
                some "cannot list /w/locked/: the file system does not allow it" &&
              pathsRefusal "/w/missing/" ==
                some "cannot list /w/missing/: nothing is at the path" &&
              pathsRefusal "/w/b.txt/" ==
                some "cannot list /w/b.txt/: what is at the path is not a directory" &&
              pathsRefusal "~/x" == some "cannot list ~/: the home directory is not known" &&
              pathsRefusal "x" (place := {}) ==
                some "cannot list ./: no directory to read it from" },
      { name :=
          "the file source is named files, of the category file, and answers later from the job files, asked again by its directory part"
        run :=
          pure
            (Completion.Paths.source.name == "files" &&
              Completion.Paths.source.category == "file" &&
              Completion.Paths.source.later == some { job := "files", reask := .beforeLast '/' } &&
              Completion.Paths.shipped.map (·.name) == #["files"]) }] ++
    -- The completion sources' contract over the file source, the files
    -- feature's shipped value; the core's `sourceContractChecks` run it over
    -- the model and the core's sources.
    (Editor.Test.sourceContract Completion.Paths.source).map fun (name, held) =>
      { name, run := pure held }

end FilesTest
