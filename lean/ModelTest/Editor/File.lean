import Editor.File
import ModelTest.Check

/-!
# Model tests: `Editor/File.lean`

The model tests of `Editor/File.lean`: `fileRefusalChecks`, pure: the refusal
a reply to each kind of file request holds. The root module `ModelTest` runs
them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- A stamp, for a result that holds one. -/
def someStamp : File.Stamp :=
  { seconds := 1, nanoseconds := 2, size := 3 }

/-- The checks of a file request's refusal (`FileRequest.refusal`,
`Editor/File.lean`), pure: for each kind of request, a refusal is the error
it holds and a result holds none. -/
def fileRefusalChecks : List Check :=
  [{  name := "a load's refusal is its error, and its result holds none"
      run :=
        let request : FileRequest := .load "/a" 10
        pure <|
          request.refusal (.error (.tooLarge 20 10) : Except FileError File.Loaded) ==
              some (.tooLarge 20 10) &&
            request.refusal
                (.ok { snapshot := ⟨1⟩, stamp := someStamp, endings := { lf := 0, crlf := 0 } } :
                  Except FileError File.Loaded) ==
              none },
    { name := "a save's refusal is its error, and its result holds none"
      run :=
        let request : FileRequest := .save (.snapshot ⟨1⟩) "/a" .absent
        pure <|
          request.refusal (.error (.changed none) : Except FileError File.Stamp) ==
              some (.changed none) &&
            request.refusal (.ok someStamp : Except FileError File.Stamp) == none },
    { name := "a stamp's refusal is its error, and its result holds none, a stamp or no file"
      run :=
        let request : FileRequest := .stamp "/a"
        pure <|
          request.refusal (.error .denied : Except FileError (Option File.Stamp)) == some .denied &&
            request.refusal (.ok (some someStamp) : Except FileError (Option File.Stamp)) == none &&
            request.refusal (.ok none : Except FileError (Option File.Stamp)) == none },
    { name := "a listing's refusal is its error, and its result holds none"
      run :=
        let request : FileRequest := .list "/a"
        pure <|
          request.refusal (.error .notADirectory : Except FileError (Array File.Entry)) ==
              some .notADirectory &&
            request.refusal
                (.ok #[{ name := "b", kind := .file }] : Except FileError (Array File.Entry)) ==
              none },
    { name := "a directory made's refusal is its error, and its result holds none"
      run :=
        let request : FileRequest := .makeDirectory "/a"
        pure <|
          request.refusal (.error .relativePath : Except FileError Unit) == some .relativePath &&
            request.refusal (.ok () : Except FileError Unit) == none },
    { name := "an append's refusal is its error, and its result holds none"
      run :=
        let request : FileRequest := .append "/a" "x".toUTF8
        pure <|
          request.refusal (.error .notAFile : Except FileError Unit) == some .notAFile &&
            request.refusal (.ok () : Except FileError Unit) == none },
    { name := "a remove's refusal is its error, and its result holds none"
      run :=
        let request : FileRequest := .remove "/a"
        pure <|
          request.refusal (.error (.failed "busy") : Except FileError Unit) ==
              some (.failed "busy") &&
            request.refusal (.ok () : Except FileError Unit) == none }]

end ModelTest
