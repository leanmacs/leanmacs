import Editor.VersionControl.Porcelain
import ModelTest.Check
import ModelTest.Support.Git
import VcApi

/-!
# Model tests: `Editor/VersionControl/Porcelain.lean`

The model tests of `Editor/VersionControl/Porcelain.lean`:
`versionControlParserChecks`. The fixtures here were captured as those of
`ModelTest.Support.Git` were, whose module doc says how. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- A detached checkout: `porcelainClean`'s commands, then `git checkout
--detach`. -/
def porcelainDetached : String :=
  "# branch.oid a655a818d91215d2e13ebd735265b112d61e150d\x00" ++ "# branch.head (detached)\x00"

/-- An unborn `main` with a staged new file: `echo a > a.txt; git add
a.txt`. -/
def porcelainUnborn : String :=
  "# branch.oid (initial)\x00" ++ "# branch.head main\x00" ++
    "1 A. N... 000000 100644 100644 0000000000000000000000000000000000000000 78981922613b2afb6025042ff6bd878ac1994e85 a.txt\x00"

/-- Files moved in the working tree and added with intent to add, which git
reads as renames in the working tree (`.R`), one of them from a file with a
staged change: `echo a > a.txt; echo b > b.txt; git add -A; g commit -m
head`, then `mv a.txt c.txt; git add -N c.txt`, then `echo staged > b.txt;
git add b.txt; mv b.txt d.txt; git add -N d.txt`. -/
def porcelainMovedIntent : String :=
  "# branch.oid d31190785150cdec68c388db596be4b901320656\x00" ++ "# branch.head main\x00" ++
    "1 M. N... 100644 100644 100644 61780798228d17af2d34fce4cfbdf35556832472 19d9cc8584ac2c7dcf57d2680375e80f099dc481 b.txt\x00" ++
    "2 .R N... 100644 100644 100644 78981922613b2afb6025042ff6bd878ac1994e85 78981922613b2afb6025042ff6bd878ac1994e85 R100 c.txt\x00" ++
    "a.txt\x00" ++
    "2 .R N... 100644 100644 100644 19d9cc8584ac2c7dcf57d2680375e80f099dc481 19d9cc8584ac2c7dcf57d2680375e80f099dc481 R100 d.txt\x00" ++
    "b.txt\x00"

/-- A file copied in the index from a file modified in the index, under a
global config that asks for copies (`[status] renames = copies`, `[diff]
renames = copies`): `echo a > a.txt; git add -A; g commit -m head`, then
`cp a.txt c.txt; echo more >> a.txt; git add -A`. The command line's
`-c status.renames=true` pins copies off, so git prints an addition. -/
def porcelainCopyPinned : String :=
  "# branch.oid a655a818d91215d2e13ebd735265b112d61e150d\x00" ++ "# branch.head main\x00" ++
    "1 M. N... 100644 100644 100644 78981922613b2afb6025042ff6bd878ac1994e85 d49c2e721b44b101b9b65c1e2847063a0f0c53b9 a.txt\x00" ++
    "1 A. N... 000000 100644 100644 0000000000000000000000000000000000000000 78981922613b2afb6025042ff6bd878ac1994e85 c.txt\x00"

/-- What `porcelainCopyPinned`'s repository prints with the command line
less its `-c` pins, `git status --porcelain=v2 -z --branch
--untracked-files=all --find-renames`, under the same config: a copy
record. -/
def porcelainCopied : String :=
  "# branch.oid a655a818d91215d2e13ebd735265b112d61e150d\x00" ++ "# branch.head main\x00" ++
    "1 M. N... 100644 100644 100644 78981922613b2afb6025042ff6bd878ac1994e85 d49c2e721b44b101b9b65c1e2847063a0f0c53b9 a.txt\x00" ++
    "2 C. N... 100644 100644 100644 78981922613b2afb6025042ff6bd878ac1994e85 78981922613b2afb6025042ff6bd878ac1994e85 C100 c.txt\x00" ++
    "a.txt\x00"

/-- Whether `text` holds `piece`. -/
def holdsText (text piece : String) : Bool :=
  (text.splitOn piece).length > 1

/-- Whether reading `printed` is refused with a reason that quotes
`quoted`. -/
def refusedQuoting (printed quoted : String) : Bool :=
  match VersionControl.Porcelain.parseStatus printed.toUTF8 with
  | .error why => holdsText why quoted
  | .ok _ => false

/-- The checks of the reader of git's porcelain status
(`Editor/VersionControl/Porcelain.lean`), on the fixtures. -/
def versionControlParserChecks : List Check :=
  let parse (printed : String) := (VersionControl.Porcelain.parseStatus printed.toUTF8).toOption
  let renameRecord :=
    "2 R. N... 100644 100644 100644 3367afdbbf91e638efe983616377c60477cc6612 3367afdbbf91e638efe983616377c60477cc6612 R100 new.txt"
  [{  name := "a clean checkout on main reads as main with no files"
      run := pure (parse porcelainClean == some { head := .branch "main" }) },
    { name := "a detached checkout reads as detached"
      run := pure (parse porcelainDetached == some { head := .detached }) },
    { name := "an unborn main with a staged new file reads as main with that file staged added"
      run :=
        pure <|
          parse porcelainUnborn ==
            some
              { head := .branch "main"
                files := #[{ path := "a.txt", state := .changed (some .added) none }] } },
    { name :=
        "every state at once reads as each file with its state, sorted by path: changes staged, unstaged and both, a rename with its origin, four kinds of conflict, untracked files in a subdirectory and with a non-ASCII name, and a path with a space"
      run := pure (parse porcelainMixed == some mixedStatus) },
    { name := "a rename record with no origin after it is refused, quoting the record"
      run := pure (refusedQuoting (porcelainClean ++ renameRecord ++ "\x00") renameRecord) },
    { name := "a record of an unknown kind is refused, quoting the record"
      run := pure (refusedQuoting (porcelainClean ++ "x what.txt\x00") "x what.txt") },
    { name := "a changed record with too few fields is refused, quoting the record"
      run :=
        pure <|
          refusedQuoting (porcelainClean ++ "1 M. N... 100644 a.txt\x00")
            "1 M. N... 100644 a.txt" },
    { name := "a changed record with an unknown XY is refused, quoting the record"
      run :=
        pure <|
          refusedQuoting
            (porcelainClean ++
              "1 Q. N... 100644 100644 100644 3367afdbbf91e638efe983616377c60477cc6612 3367afdbbf91e638efe983616377c60477cc6612 q.txt\x00")
            "q.txt" },
    { name :=
        "files moved in the working tree and added with intent to add read as git prints them with renames off: each origin an unstaged deletion, joined with its own staged change, and each new path an unstaged addition"
      run :=
        pure <|
          parse porcelainMovedIntent ==
            some
              { head := .branch "main"
                files :=
                  #[{ path := "a.txt", state := .changed none (some .deleted) },
                    { path := "b.txt", state := .changed (some .modified) (some .deleted) },
                    { path := "c.txt", state := .changed none (some .added) },
                    { path := "d.txt", state := .changed none (some .added) }] } },
    { name :=
        "a copy git prints with copies pinned off reads as a staged addition beside the staged modification it was copied from"
      run :=
        pure <|
          parse porcelainCopyPinned ==
            some
              { head := .branch "main"
                files :=
                  #[{ path := "a.txt", state := .changed (some .modified) none },
                    { path := "c.txt", state := .changed (some .added) none }] } },
    { name := "a copy record is refused, since the command line pins copies off"
      run := pure (refusedQuoting porcelainCopied "c.txt") },
    { name := "output with no branch.head header is refused"
      run := pure (parse "? a.txt\x00" == none) },
    { name := "output that is not UTF-8 is refused"
      run :=
        pure <|
          VersionControl.Porcelain.parseStatus
              (porcelainClean.toUTF8 ++ ByteArray.mk #[63, 32, 0xff, 0]) matches
            .error _ }]

end ModelTest
