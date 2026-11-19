-- The default config `mise run install` puts in ~/.config/leanmacs when
-- none is there: a starter map under the leader (`SPC` in the Vim scheme),
-- after Doom Emacs's `SPC` keys, over commands the editor already ships.
-- Each binding has a description and each prefix a name, for the key hints.
-- `SPC :` opens the command prompt, which runs any registered command by
-- name, and `SPC ?` the binding search, which lists every binding the view
-- can reach and runs the one chosen as its key would. `SPC SPC` and
-- `SPC p f` find a file in the buffer's workspace, and `SPC p p` picks
-- another workspace of the project and finds a file in it.
--
-- The map is `leaderMap`, in a config file of its own, apart from the root's
-- `setup` (in `init.lean`), so it can be dropped into a config of your own:
-- copy this file to `Config/Leader.lean` there, write `import Config.Leader`
-- in your `init.lean`, and call `leaderMap` from your `setup`. The editor
-- runs only the `setup` that `init.lean` defines; a file under `Config/`
-- exports its programs under names of their own, as this one does.
--
-- docs/design/keymaps-and-modes.md, "Extending from config", compares the
-- keys with Doom's.

import Editor

open Editor

def leaderMap : SetupM Unit := do
  prefixName "<leader> f" "file"
  prefixName "<leader> b" "buffer"
  prefixName "<leader> w" "window"
  prefixName "<leader> TAB" "tab"
  prefixName "<leader> h" "help"
  prefixName "<leader> p" "project"
  -- Top level.
  bindKey "<leader> ." "open-file" (desc := "Find file")
  bindKey "<leader> ," "switch-buffer" (desc := "Switch buffer")
  bindKey "<leader> :" "execute-command" (desc := "Execute command")
  bindKey "<leader> ?" "search-bindings" (desc := "Search bindings")
  bindKey "<leader> SPC" "find-file-in-workspace" (desc := "Find file in workspace")
  -- project
  bindKey "<leader> p f" "find-file-in-workspace" (desc := "Find file in workspace")
  bindKey "<leader> p p" "find-file-in-project" (desc := "Switch workspace")
  -- file
  bindKey "<leader> f f" "open-file" (desc := "Find file")
  bindKey "<leader> f s" "save-buffer" (desc := "Save file")
  -- buffer
  bindKey "<leader> b b" "switch-buffer" (desc := "Switch buffer")
  bindKey "<leader> b i" "list-buffers" (desc := "List buffers")
  bindKey "<leader> b k" "close-buffer" (desc := "Kill buffer")
  bindKey "<leader> b d" "close-buffer" (desc := "Kill buffer")
  bindKey "<leader> b s" "save-buffer" (desc := "Save buffer")
  bindKey "<leader> b r" "reload-buffer" (desc := "Revert buffer")
  -- window: Vim's `C-w` keys, Doom's `SPC w`. No tab key competes here, so
  -- `n`, `p`, `c` and `w` keep Vim's window meanings.
  for (key, command, desc) in
      [("s", "window-split", "Split window"),
        ("v", "window-split-vertically", "Split window vertically"),
        ("n", "window-new", "New window"), ("c", "window-close", "Close window"),
        ("q", "window-quit", "Quit window"), ("o", "window-only", "Close other windows"),
        ("h", "window-focus-left", "Window left"), ("j", "window-focus-down", "Window below"),
        ("k", "window-focus-up", "Window above"), ("l", "window-focus-right", "Window right"),
        ("w", "window-focus-next", "Next window"),
        ("W", "window-focus-previous", "Previous window"),
        ("t", "window-focus-top", "Top window"), ("b", "window-focus-bottom", "Bottom window"),
        ("p", "window-focus-last", "Last window"), ("x", "window-exchange", "Exchange windows"),
        ("r", "window-rotate", "Rotate windows"), ("R", "window-rotate-back", "Rotate windows back"),
        ("=", "window-balance", "Balance windows"), ("+", "window-taller", "Taller"),
        ("-", "window-shorter", "Shorter"), (">", "window-wider", "Wider"),
        ("<", "window-narrower", "Narrower"), ("z", "window-zoom", "Zoom window"),
        ("m", "window-promote", "Make main"), ("M", "window-demote", "Demote from main"),
        (",", "window-main-more", "More main windows"),
        (".", "window-main-fewer", "Fewer main windows"),
        ("H", "window-edge-left", "Dock left"), ("J", "window-edge-bottom", "Dock bottom"),
        ("K", "window-edge-top", "Dock top"), ("L", "window-edge-right", "Dock right"),
        ("F", "window-float", "Float window")] do
    bindKey s!"<leader> w {key}" command (desc := desc)
  -- tab: Doom's `SPC TAB` workspace keys.
  bindKey "<leader> TAB ." "tab-switch" (desc := "Switch tab")
  bindKey "<leader> TAB n" "tab-new" (desc := "New tab")
  bindKey "<leader> TAB d" "tab-close" (desc := "Close tab")
  bindKey "<leader> TAB r" "tab-rename" (desc := "Rename tab")
  bindKey "<leader> TAB ]" "tab-next" (desc := "Next tab")
  bindKey "<leader> TAB [" "tab-previous" (desc := "Previous tab")
  for index in List.range 9 do
    bindKey s!"<leader> TAB {index + 1}" s!"tab-select-{index + 1}" (desc := s!"Tab {index + 1}")
  -- help
  bindKey "<leader> h t" "load-theme" (desc := "Load theme")
