import Editor.Config.Registry
import Editor.Display
import Editor.Display.Model
import Editor.Event
import Editor.File
import Editor.InputScheme.Test
import Editor.Loop.Driver
import Editor.Menu
import Editor.State
import Editor.Test.Driver
import Editor.Test.Models
import Editor.Text

/-!
# The test kit: Frame

A driver whose keys, commands and menu bar are a registry's, and what a
check reads of the window's frame: for the checks of the frame commands
and of the menu, the packages' and the core's, on the test scheme
(`Editor/InputScheme/Test.lean`). It takes the registry and the menu it is
handed, so it names no package.

- **`frameKeys`**: what a step is handed: the active keymaps the registry
  makes from the loop's state, its plain commands and those given their
  call, and a menu, when one is handed, with its command items' key
  equivalents filled from the registry, as a host's are
  (`Config.Registry.menuOf`).
- **`frameDriverOver`**: a driver over the initial state with those keys
  and the kit's driver jobs; with `held` the scratch buffer holds a file,
  made up and never loaded, so that an edit of it is an unsaved change.
- **`resizedTo`**: the window's word that it is 640 by 480 at scale 1, in
  fullscreen or not.
- **`framed`**: what the display model was asked of the window, and
  whether the frame last said it is in fullscreen, after some events.

It holds no checks. It is pinned by the checks that run on it.

Published for a package's tests: it is a module of the core's test kit, a
test double in the namespace `Editor.Test`, which a package's test modules
may import and its library may not (`docs/design/packages.md`, "What a
package may import").
-/

namespace Editor.Test

open Editor

/-- What a step of the frame and menu checks is handed: the active keymaps
`registry` makes for the test scheme from the loop's state, its plain
commands and those given their call, and `menu`, when there is one, with
its key equivalents filled from `registry`, as a host's are. -/
def frameKeys (registry : Config.Registry) (menu : Option Menu := none) :
    Loop.Keys TestScheme.scheme :=
  { maps := registry.activeMaps TestScheme.scheme
    command? := fun name =>
      match registry.find? name with
      | some { registration := { action := .plain run, .. }, .. } =>
        some fun _ => do
          run
          return none
      | some { registration := { action := .call run, .. }, .. } =>
        some fun call => do
          run call
          return none
      | _ => none
    menu := menu.map registry.menuOf }

/-- A driver of the frame and menu checks over the initial state, with the
keys of `registry` and `menu` (`frameKeys`); `none` if making the state was
refused. With `held` the scratch buffer holds a file, made up and never
loaded, so that an edit of it is an unsaved change. -/
def frameDriverOver (registry : Config.Registry) (menu : Option Menu := none)
    (held : Bool := false) : Option TestDriver :=
  let start : TextM EditorState := do
    let state ← EditorState.initial ⟨640, 480⟩
    if held then
      return (state.attachFile ⟨0⟩ "/files/note.txt" { seconds := 0, nanoseconds := 0, size := 0 }
            .lf).2
    return state
  (Loop.Driver.over (frameKeys registry menu) driverJobs start editorModel).toOption

/-- The window's word that it is 640 by 480 at scale 1, in fullscreen or not. -/
def resizedTo (fullscreen : Bool) : Event :=
  .resize { width := 640, height := 480, scale := 1.0, fullscreen }

/-- What `driver`'s display model was asked of the window, and whether the
frame last said it is in fullscreen, after `events`; `none` without a
driver. -/
def framed (driver : Option TestDriver) (events : List Event) :
    Option (Array Display.FrameRequest × Bool) :=
  driver.map fun driver =>
    let fed := (fedTo driver events).1
    (fed.model.display.asked, fed.loop.state.frame.fullscreen)

end Editor.Test
