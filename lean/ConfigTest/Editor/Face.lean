import ConfigTest.Check
import ConfigTest.Support.Hosts
import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Completion
import Editor.Config.Directory
import Editor.Config.Elaborate
import Editor.Config.Registry
import Editor.Display.Real
import Editor.Event
import Editor.Event.Queue
import Editor.Ex.Line
import Editor.Face
import Editor.Ffi.Display
import Editor.Ffi.Window
import Editor.Fuzzy.Real
import Editor.Headless
import Editor.InputScheme.Test
import Editor.Job.Runner
import Editor.Language
import Editor.Loop
import Editor.Mode
import Editor.Program
import Editor.Scene
import Editor.Text
import Editor.Text.Real

/-!
# Config tests: `Editor/Face.lean`

The tests of `Editor/Face.lean`: `faceChecks`, through the headless host. The
root module `ConfigTest` runs them; its module doc says what each shows.
-/

namespace ConfigTest

open Editor

/-- A config of one file whose `setup` is `body`, a line of Lean. -/
def faceText (body : String) : String :=
  s!"def setup : SetupM Unit := do\n  {body}\n"

/-- The checks that a face set in config reaches the frame: a config
directory of real files, the real elaborator, a host whose reloads re-theme
its display, the display's real binding and the library's layout. What a
face looks like in
a frame is layout's rule, so a frame is compared with another frame: the
one a second display, which the check makes itself, lays out of the same
scene in a theme written here. That display is handed the same themes in
the same order, since a frame's text names fonts by the ids its shaper gave
them. No colour, size or frame text is written here. -/
def faceChecks (context : Context) : List Check :=
  [{
      name :=
        "changing a face in config and reloading changes the next frame, to the frame the built-in theme followed by config's definition gives: a colour, then a size; a rejected reload leaves the frame as it was; and a config that sets no face gives the built-in theme's frame",
      run :=
        IO.FS.withTempDir fun directory => do
          let write (body : String) : IO Unit :=
            writeConfig directory [("init.lean", faceText body)]
          let over (attributes : Face) : Theme :=
            Theme.builtin ++ #[{ name := ⟨"default"⟩, face := attributes }]
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          -- The host's display: the real binding over the library's layout
          -- in cells 8 by 16, which the check keeps to read its frame and the
          -- scene the host last published.
          let library ← Ffi.Display.newCells 8 16
          let made ← IO.mkRef (none : Option Headless.Host.Display)
          let collaborators :=
            { stage.collaborators with
              display := fun snapshots => do
                let display ←
                  Headless.Host.Display.real (← RealDisplay.over library snapshots Theme.builtin)
                made.set (some display)
                return display }
          -- The second display, over the same table of snapshots, handed the
          -- themes the host's is handed, in the same order.
          let mirror ←
            RealDisplay.over (← Ffi.Display.newCells 8 16) collaborators.published.reader
                Theme.builtin
          onStage { stage with collaborators } fun host _ => do
              -- Names the first of `parts` that does not hold.
              let holds (parts : List (String × Bool)) : IO Unit := do
                if let some (part, _) := parts.find? (!·.2) then
                  throw (IO.userError part)
              let settled : IO Unit := do
                unless ← host.settle patience do
                  throw (IO.userError "the editor thread did not settle")
              -- The host's frame of the last scene it published, and the
              -- second display's frame of that scene, in `theme` when it is
              -- given and in the theme it last had otherwise.
              let frames (theme : Option Theme) : IO (String × String) := do
                let some display ← made.get | throw (IO.userError "the host made no display")
                let some scene ← display.last? | throw (IO.userError "the host published no scene")
                if let some theme := theme then
                  mirror.setTheme theme
                mirror.publish scene
                return (← library.frameText, ← mirror.display.frameText)
              let reload : IO Unit := do
                host.send .reload
                settled
              -- The frame is made, with a view of some size and a text in
              -- it, in the built-in theme.
              host.resize 160 96
              unless ← Event.post (.commit "let x = 1") do
                return false
              settled
              let (plain, plainMirror) ← frames none
              holds [("the first frame is the built-in theme's", plain == plainMirror)]
              -- (a) A face set in config is in the first frame after the reload.
              write "face \"default\" { foreground := some (Color.rgb 200 0 0) }"
              reload
              let (red, redMirror) ← frames (over { foreground := some (Color.rgb 200 0 0) })
              holds
                  [("(a) the frame after the reload differs", red != plain),
                    ("(a) and is the one config's face gives", red == redMirror)]
              -- (b), (c) Changed in the file and reloaded, it changes the frame,
              -- to the one the changed face gives.
              write "face \"default\" { foreground := some (Color.rgb 0 200 0) }"
              reload
              let (green, greenMirror) ← frames (over { foreground := some (Color.rgb 0 200 0) })
              holds
                  [("(b) the frame after a changed colour differs", green != red),
                    ("(c) and is the one the changed face gives", green == greenMirror)]
              -- (d) An attribute that changes shaping.
              write "face \"default\" { size := some 32 }"
              reload
              let (large, largeMirror) ← frames (over { size := some 32 })
              holds
                  [("(d) the frame after a changed size differs", large != green),
                    ("(d) and is the one the size gives", large == largeMirror)]
              -- (e) A config that does not elaborate: rejected, and no face moved.
              write "face \"default\" { size := some 8 }\n\ndef broken : Nat := \"not a number\""
              reload
              -- Its error is in the echo area now, so the scene is not the one
              -- before; its frame is the one that scene gives in the faces
              -- before.
              let (kept, keptMirror) ← frames none
              holds
                  [("(e) after a rejected reload the frame is the one the faces before give",
                      kept == keptMirror)]
              -- (f) A config that sets no face: the built-in theme again.
              write "pure ()"
              reload
              let (unset, unsetMirror) ← frames Theme.builtin
              let lines ← stage.output.get
              holds
                  [("(f) its frame is the built-in theme's", unset == unsetMirror),
                    ("(f) which is not the frame before", unset != large),
                    ("every reload but (e) installed and (e) was rejected",
                      (lines.filter (·.startsWith "reload ")).map (·.endsWith "rejected") ==
                        #[false, false, false, true, false])]
              return true },
    {
      name :=
        "a real config that sets the frame padding to 12 installs, and the next scene's views are padded 12 and the library's frame draws its rows 12 in; rewritten to 0 and reloaded in the same host, with no restart, the views are padded 0 and no row is drawn in from the view's edge",
      run :=
        IO.FS.withTempDir fun directory => do
          let write (points : Nat) : IO Unit :=
            writeConfig directory [("init.lean", faceText s!"framePadding {points}")]
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          -- The host's display: the real binding over the library's layout in
          -- cells 8 by 16, at scale 1, which the check keeps to read its frame
          -- and the scene the host last published.
          let library ← Ffi.Display.newCells 8 16
          let made ← IO.mkRef (none : Option Headless.Host.Display)
          let collaborators :=
            { stage.collaborators with
              display := fun snapshots => do
                let display ←
                  Headless.Host.Display.real (← RealDisplay.over library snapshots Theme.builtin)
                made.set (some display)
                return display }
          onStage { stage with collaborators } fun host _ => do
              let settled : IO Unit := do
                unless ← host.settle patience do
                  throw (IO.userError "the editor thread did not settle")
              let reload : IO Unit := do
                host.send .reload
                settled
              -- The paddings of the views of the last scene, and the frame.
              let shown : IO (Array Padding × String) := do
                let some display ← made.get | throw (IO.userError "the host made no display")
                let some scene ← display.last? | throw (IO.userError "the host published no scene")
                return (scene.views.map (·.padding), ← library.frameText)
              write 12
              host.resize 160 96
              unless ← Event.post (.commit "let x = 1") do
                return false
              reload
              let (twelve, padded) ← shown
              write 0
              reload
              let (zero, plain) ← shown
              let lines ← stage.output.get
              return twelve == #[{ across := 12, down := 12 }] &&
                  (padded.splitOn "  row x 12 y 12 ").length > 1 &&
                  zero == #[{}] &&
                  (plain.splitOn "  row x ").length == 1 &&
                  (lines.filter (·.startsWith "reload ")).all (·.endsWith "commands") },
    {
      name :=
        "a reload that makes mode-line taller sizes the scene published after it by the new heights: agree, asked with no event between the reload and it, says the last rows query about the focused view gave the rows of the frame, as it did before the reload",
      run :=
        IO.FS.withTempDir fun directory => do
          -- `top` puts the cursor at the text's start, so that no follow
          -- scrolls the view: `agree` compares rows from one anchor.
          let top : Config.Registration :=
            { name := "top"
              action :=
                .call fun call => call.target.select { ranges := #[⟨0, 0⟩], shape := .exclusive } }
          let stage ←
            Stage.new context context.elaborator (Config.Directory.source directory)
                { commands := #[top] }
          -- The host's display: the real binding over the library's layout
          -- in cells 8 by 16, in the built-in theme.
          let collaborators :=
            { stage.collaborators with
              display := fun snapshots => do
                Headless.Host.Display.real
                    (← RealDisplay.over (← Ffi.Display.newCells 8 16) snapshots Theme.builtin) }
          onStage { stage with collaborators } fun host _ => do
              let settled : IO Unit := do
                unless ← host.settle patience do
                  throw (IO.userError "the editor thread did not settle")
              -- What `agree` says now.
              let agreement : IO String := do
                host.send .agree
                settled
                return (← stage.output.get).back?.getD ""
              -- A view of some rows, over a text of more lines than it shows.
              host.resize 160 96
              let text := "\n".intercalate ((List.range 20).map toString)
              unless ← Event.post (.commit text) do
                return false
              host.send (.run "top")
              settled
              let before ← agreement
              writeConfig directory
                  [("init.lean", faceText "face \"mode-line\" { size := some 32 }")]
              host.send .reload
              settled
              let after ← agreement
              let lines ← stage.output.get
              if !(before.endsWith ": agrees" && after.endsWith ": agrees") then
                throw (IO.userError s!"before the reload: {before}; after it: {after}")
              return lines.any (·.startsWith "reload 1: installed") }]

end ConfigTest
