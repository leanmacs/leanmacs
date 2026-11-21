import WorkingSet
import WorkingSetTest.Check

/-!
# Model tests: `WorkingSet.lean`

The model tests of `WorkingSet.lean`: `workingSetChecks`. The test driver's
root, `WorkingSetTest/Model.lean`, runs them; its module doc says what each
shows.
-/

namespace WorkingSetTest

open Editor

/-- A document with one set of two ranges, one of them with characters that
are not ASCII and a note, for the round trips. -/
def workingSetDocument : WorkingSet.Document :=
  { root := "/w/a%b"
    sets :=
      #[{ name := "auth"
          ranges :=
            #[{ path := "src/a.rs", commit := "c0ffee", quote := "fn main() {\n", before := "",
                after := "    println!(\"é\");", start := ⟨1, 1⟩, stop := ⟨2, 1⟩ },
              { path := "src/漢.rs", quote := "\"quoted\" \\ tab\t", before := "x", after := "",
                start := ⟨12, 5⟩, stop := ⟨12, 21⟩, note := "look here" }] },
        { name := "empty" }] }

/-- The checks of the working set's stored form (`WorkingSet.lean`):
its JSON round trip and the refusals of a document it cannot read, the key
of a workspace's directory, a range captured from a text and found again by
its points, the headers, and the excerpts' grouping. Pure. -/
def workingSetChecks : List Check :=
  [{  name :=
        "a working set document written and read again is the document: its version, its root, its sets in order and every field of each range"
      run :=
        return WorkingSet.Document.read workingSetDocument.render.toUTF8 |>.toOption |>.any
            (· == workingSetDocument) },
    { name :=
        "a working set document is written as version 1 JSON with the range's fields named as rdm's anchor names them"
      run :=
        let one : WorkingSet.Document :=
          { root := "/w"
            sets :=
              #[{ name := "s"
                  ranges := #[{ path := "a", quote := "q", start := ⟨1, 2⟩, stop := ⟨3, 4⟩ }] }] }
        return one.render ==
            "{\"version\":1,\"root\":\"/w\",\"sets\":[{\"name\":\"s\",\"ranges\":[{\"path\":\"a\",\"commit\":\"\",\"quote\":\"q\",\"prefix\":\"\",\"suffix\":\"\",\"start\":{\"line\":1,\"column\":2},\"stop\":{\"line\":3,\"column\":4},\"note\":\"\"}]}]}" },
    { name :=
        "a working set document of a newer version is refused, saying so; one that does not parse, or lacks a field, is refused with why"
      run :=
        let refusal (text : String) : Option String :=
          match WorkingSet.Document.read text.toUTF8 with
          | .error why => some why
          | .ok _ => none
        return refusal "{\"version\":2,\"root\":\"/w\",\"sets\":[]}" ==
              some "version 2 is newer than this editor's 1" &&
            refusal "{\"version\":1,\"root\":\"/w\",\"sets\":[]" == some "an object is not closed" &&
            refusal "{\"version\":1,\"sets\":[]}" == some "root is not a string" &&
            refusal "{\"root\":\"/w\",\"sets\":[]}" == some "version is not a number" &&
            refusal "{\"version\":1,\"root\":\"/w\",\"sets\":[{\"name\":\"s\",\"ranges\":[{}]}]}" ==
              some "path is not a string" &&
            (WorkingSet.Document.read "{\"version\":1,\"root\":\"/w\",\"sets\":[]}".toUTF8).toOption ==
              some { root := "/w" } },
    { name :=
        "a workspace's directory is its root with % written %25 and / written %2F, under workspaces in the state directory"
      run :=
        return WorkingSet.key "/w/a%b" == "%2Fw%2Fa%25b" &&
            WorkingSet.storeFile "/state" "/w" == "/state/workspaces/%2Fw/working-sets.json" &&
            WorkingSet.storeDirectory "/state" "/w/x" == "/state/workspaces/%2Fw%2Fx" },
    { name :=
        "a range captured from a text keeps its quote, up to 32 characters each side, and its 1-based lines and columns, counted in characters"
      run :=
        let text := "one\ntwo three\nfour"
        -- `three`: bytes 8 to 13, on line 2 from column 5 to 10.
        let three := WorkingSet.capture text 8 13 "a.txt" "c0ffee" "n"
        let long := String.ofList (List.replicate 40 'x') ++ "MID" ++ String.ofList (List.replicate 40 'y')
        let middle := WorkingSet.capture long 40 43 "b.txt"
        return three ==
              { path := "a.txt", commit := "c0ffee", note := "n", quote := "three"
                before := "one\ntwo ", after := "\nfour", start := ⟨2, 5⟩, stop := ⟨2, 10⟩ } &&
            middle.quote == "MID" && middle.before == String.ofList (List.replicate 32 'x') &&
            middle.after == String.ofList (List.replicate 32 'y') },
    { name :=
        "a range captured at the start and at the end of a text has no context on that side, and one in text that is not ASCII counts columns in characters and cuts its context on characters"
      run :=
        let text := "αβγ\nδεζ"
        let whole := WorkingSet.capture text 0 text.utf8ByteSize "a"
        -- `ε`: bytes 9 to 11, line 2, column 2.
        let epsilon := WorkingSet.capture text 9 11 "a"
        let wide := String.ofList (List.replicate 40 '漢') ++ "x"
        let x := WorkingSet.capture wide 120 121 "a"
        return whole.before == "" && whole.after == "" && whole.quote == text &&
            whole.start == ⟨1, 1⟩ && whole.stop == ⟨2, 4⟩ &&
            epsilon.quote == "ε" && epsilon.before == "αβγ\nδ" && epsilon.after == "ζ" &&
            epsilon.start == ⟨2, 2⟩ && epsilon.stop == ⟨2, 3⟩ &&
            x.before == String.ofList (List.replicate 32 '漢') && x.start == ⟨1, 41⟩ },
    { name :=
        "a point is found again as the byte offset it was captured at, and a line or a column past the end is clamped to the text's end and the line's end"
      run :=
        let text := "αβγ\nδεζ\n"
        let bytes := text.toUTF8
        return (WorkingSet.Point.offsetIn ⟨2, 2⟩ bytes) == 9 &&
            (WorkingSet.Point.offsetIn ⟨1, 1⟩ bytes) == 0 &&
            (WorkingSet.Point.offsetIn ⟨1, 99⟩ bytes) == 6 &&
            (WorkingSet.Point.offsetIn ⟨3, 1⟩ bytes) == 14 &&
            (WorkingSet.Point.offsetIn ⟨9, 4⟩ bytes) == 14 &&
            [0, 2, 6, 7, 9, 13, 14].all fun offset =>
              (WorkingSet.pointAt bytes offset).offsetIn bytes == offset },
    { name :=
        "an excerpt's header is its path and line, changed when a range was found with errors, and each note; a drifted one says since the commit's first eight characters when it has one"
      run :=
        let stored : WorkingSet.Stored :=
          { path := "a.txt", commit := "c0ffee1234567890", quote := "q", start := ⟨7, 1⟩
            stop := ⟨7, 2⟩, note := "why" }
        return WorkingSet.header "a.txt" 2 false #[] == "a.txt:2" &&
            WorkingSet.header "a.txt" 2 true #["one", "", "two"] == "a.txt:2 · changed · one · two" &&
            WorkingSet.driftedHeader stored == "a.txt:7 · drifted since c0ffee12 · why" &&
            WorkingSet.driftedHeader { stored with commit := "", note := "" } == "a.txt:7 · drifted" },
    { name :=
        "a set's excerpts are grouped by file in the order of each file's first range, and ranges of one file whose rows overlap or touch are one excerpt"
      run :=
        let excerpts :=
          WorkingSet.excerpts
            #[("b.txt", 10, 10), ("a.txt", 4, 6), ("b.txt", 2, 3), ("a.txt", 5, 5), ("a.txt", 7, 8),
              ("a.txt", 20, 20)]
        return excerpts ==
            #[{ path := "b.txt", first := 2, last := 3, ranges := #[2] },
              { path := "b.txt", first := 10, last := 10, ranges := #[0] },
              { path := "a.txt", first := 4, last := 8, ranges := #[1, 3, 4] },
              { path := "a.txt", first := 20, last := 20, ranges := #[5] }] },
    { name :=
        "the sentences: the buffer's name, the prompts, the store that cannot be read, memory only, already in, two files, no file, opened and not saved"
      run :=
        return WorkingSet.bufferName "demo" "w" == "*working-set: demo in w*" &&
            WorkingSet.addPrompt "w" == "Add to working set (w): " &&
            WorkingSet.openPrompt "w" == "Open working set (w): " &&
            WorkingSet.unreadableSentence "w" "/s/f.json" "version 2 is newer than this editor's 1" ==
              "working sets of w: /s/f.json cannot be read: version 2 is newer than this editor's 1; it is left as it is" &&
            WorkingSet.memoryOnlySentence ==
              "working sets are not kept across restarts: no state directory" &&
            WorkingSet.alreadyIn "demo" == "already in demo" &&
            WorkingSet.spansTwoFiles == "working-set-add: the selection spans two files" &&
            WorkingSet.noFile "*review*" == "working-set-add: *review* has no file" &&
            WorkingSet.openedSentence "demo" 3 1 == "demo: 3 ranges, 1 drifted" &&
            WorkingSet.notSavedSentence "w" "denied" == "working sets of w not saved: denied" }]

end WorkingSetTest
