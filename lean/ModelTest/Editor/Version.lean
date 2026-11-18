import Editor.Version
import ModelTest.Check

/-!
# Model tests: `Editor/Version.lean`

The model tests of `Editor/Version.lean`: `versionChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- A plist text in the shape lakefile `appInfoPlist` writes, document types
nested above the stamp, with `stamp` spliced in where it writes the three
keys; `extra` goes just before the closing `</dict>`. -/
def versionPlist (stamp : String) (extra : String := "") : String :=
  s!"<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
\t<key>CFBundleDocumentTypes</key>
\t<array>
\t\t<dict>
\t\t\t<key>CFBundleTypeName</key>
\t\t\t<string>Text</string>
\t\t\t<key>LSItemContentTypes</key>
\t\t\t<array>
\t\t\t\t<string>public.text</string>
\t\t\t</array>
\t\t</dict>
\t</array>
\t<key>CFBundleExecutable</key>
\t<string>editor</string>
{stamp}\t<key>LSMinimumSystemVersion</key>
\t<string>26.0</string>
\t<key>NSHighResolutionCapable</key>
\t<true/>
{extra}</dict>
</plist>
"

/-- The three keys of a stamp as `appInfoPlist` writes them. -/
def versionStampKeys (version build commit : String) : String :=
  s!"\t<key>CFBundleShortVersionString</key>
\t<string>{version}</string>
\t<key>CFBundleVersion</key>
\t<string>{build}</string>
\t<key>LeanmacsCommit</key>
\t<string>{commit}</string>
"

/-- The checks of `editor --version` (`Editor/Version.lean`): what it prints
for a stamp, a development build and an unreadable plist; the plist reader
on the shape `editorApp` writes, and each text it refuses; and what it
reads, through a fake file read. -/
def versionChecks : List Check :=
  let sha := String.ofList (List.replicate 40 'a')
  let stamp : Version.Stamp := { version := "0.0.1", build := "20010203040506", commit := sha }
  let good := versionPlist (versionStampKeys "0.0.1" "20010203040506" sha)
  let refusal (plist : String) : Option String :=
    match Version.ofInfoPlist plist with
    | .error reason => some reason
    | .ok _ => none
  let names (key : String) (plist : String) : Bool :=
    match refusal plist with
    | some reason => reason.startsWith key
    | none => false
  -- A fake file read: records each path asked, and answers `answer`.
  let fake (answer : Except String String) (path : System.FilePath) :
    StateM (Array System.FilePath) (Except String String) := do
    modify (·.push path)
    pure answer
  [{  name :=
        "a stamped build reports the version, the build ID and the commit on three lines, with status 0"
      run :=
        pure
          (Version.report (.stamped stamp) ==
            (s!"Leanmacs 0.0.1\nbuild 20010203040506\ncommit {sha}", 0)) },
    { name := "a development build says it has no version, build ID or commit, with status 0"
      run :=
        pure
          (Version.report .development ==
            ("Leanmacs, a development build: not run from an app bundle, so it has no version, build ID or commit",
              0)) },
    { name := "an unreadable plist reports its path and the reason, with status 1"
      run :=
        pure
          (Version.report (.unreadable "/x/Leanmacs.app/Contents/Info.plist" "no such file") ==
            ("Leanmacs: /x/Leanmacs.app/Contents/Info.plist: no such file", 1)) },
    { name :=
        "the plist reader takes the stamp from the shape appInfoPlist writes, document types nested above it"
      run := pure ((Version.ofInfoPlist good).toOption == some stamp) },
    { name :=
        "the plist reader refuses a missing LeanmacsCommit, a key given twice, an <integer>, a binary plist and a value with &, each naming the key"
      run :=
        let noCommit :=
          versionPlist
            "\t<key>CFBundleShortVersionString</key>\n\t<string>0.0.1</string>\n\t<key>CFBundleVersion</key>\n\t<string>20010203040506</string>\n"
        let twice :=
          versionPlist (versionStampKeys "0.0.1" "20010203040506" sha)
            "\t<key>CFBundleVersion</key>\n\t<string>20010203040507</string>\n"
        let integer :=
          versionPlist
            (versionStampKeys "0.0.1" "20010203040506" sha |>.replace
              "<string>20010203040506</string>" "<integer>20010203040506</integer>")
        let entity := versionPlist (versionStampKeys "0.0.1&amp;" "20010203040506" sha)
        pure
          (refusal noCommit == some "LeanmacsCommit is missing" &&
            refusal twice == some "CFBundleVersion is given more than once" &&
            refusal integer == some "CFBundleVersion is not a <string>" &&
            names "CFBundleShortVersionString" ("bplist00" ++ good) &&
            names "CFBundleShortVersionString" entity) },
    { name :=
        "in a bundle it reads exactly Contents/Info.plist, once, and returns the stamp; outside one it reads nothing and is a development build"
      run :=
        let (inBundle, asked) :=
          (Version.read "/x/Leanmacs.app/Contents/MacOS/editor" (fake (.ok good))).run #[]
        let (outside, askedOutside) :=
          (Version.read "/x/.lake/build/bin/editor" (fake (.ok good))).run #[]
        pure
          (inBundle == .stamped stamp &&
            asked == #[System.FilePath.mk "/x/Leanmacs.app/Contents/Info.plist"] &&
            outside == .development &&
            askedOutside.isEmpty) },
    { name :=
        "a read that fails, or a plist with no stamp, is unreadable, with the plist's path and the reason"
      run :=
        let failed : Version.Build :=
          (Version.read "/x/Leanmacs.app/Contents/MacOS/editor" (fake (.error "no such file"))).run'
            #[]
        let empty : Version.Build :=
          (Version.read "/x/Leanmacs.app/Contents/MacOS/editor" (fake (.ok (versionPlist "")))).run'
            #[]
        pure
          (failed == .unreadable "/x/Leanmacs.app/Contents/Info.plist" "no such file" &&
            empty ==
              .unreadable "/x/Leanmacs.app/Contents/Info.plist"
                "CFBundleShortVersionString is missing") }]

end ModelTest
