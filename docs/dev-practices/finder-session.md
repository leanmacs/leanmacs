# The Finder session, by hand

The owner's checklist for phase 6 of the macOS app roadmap
(`rdm:phase/macos-app/phase-6-finder-session`), and the roadmap's signal:
the app, installed in `/Applications`, opens a file from Finder, edits it
with the Vim scheme, saves it, and runs a command from config in
`~/.config/leanmacs`. Every step needs a person at a Mac: a real window,
Finder, the Dock, the green button and an input method. No agent runs it.

Run the whole list in one sitting. Each step gives the exact keys or
commands, **Expect:** what should be seen, and **Seen:** to fill in. Copy
the filled list into the phase body.

## Record

- Date: ____
- Commit (`git rev-parse HEAD`): ____
- Machine: ____
- macOS (`sw_vers`): ____
- Input methods used: ____
- `vtool -show-build /Applications/Leanmacs.app/Contents/MacOS/editor`: ____

## Steps

0. **Preparation.** In the checkout: `git status` shows nothing to commit.
   Then `mise run finder-session-prepare` ([`on-demand-checks.md`](on-demand-checks.md),
   "The Finder session, by hand"). Then make the three test files afresh, so
   a second sitting starts from the same state:

   ```sh
   rm -f /tmp/finder-session.txt /tmp/finder-session-2.txt /tmp/finder-session.c
   printf 'hello\n' > /tmp/finder-session.txt
   printf 'second\n' > /tmp/finder-session-2.txt
   printf 'int main(void) { return 0; }\n' > /tmp/finder-session.c
   ```

   **Expect:** `app-check: ok`, the installed path, the backups made (or
   "nothing to back up"), the timestamp and the restore commands. Note
   them. **Seen:** ____

### The window on winit 0.31 (phase 3), in the checkout

1. `mise run window-contract`. **Expect:** one line from the contract
   example, then the second window's `window: ready for input`; it exits 0.
   **Seen:** ____
2. `mise run edit -- /tmp/finder-session.txt`; `i`, type `abc`, Escape.
   **Expect:** the letters appear as typed, once each. **Seen:** ____
3. Dead key: `i`, Option-e then `e`, Escape. **Expect:** `é` is inserted.
   **Seen:** ____
4. IME: switch to Japanese Kana (or another IME), `i`, type `nihon`; Space
   to convert, Return to commit; switch back; Escape. **Expect:** the
   preedit shows underlined, and the chosen candidate is inserted.
   **Seen:** ____
5. Click in the text; then, in `mise run edit -- lean/Editor/Loop.lean`,
   scroll with two fingers. **Expect:** the cursor moves to the click; the
   view moves with the scroll. **Seen:** ____
6. Drag a window corner. **Expect:** the text redraws at the new size.
   **Seen:** ____
7. Green button into fullscreen and out. **Expect:** the text redraws at
   each size. **Seen:** ____

### Requests to the window (phase 4), in the same window

8. Ctrl-Cmd-F. **Expect:** it enters fullscreen. **Seen:** ____
9. Ctrl-Cmd-F again. **Expect:** it leaves fullscreen. **Seen:** ____
10. Green button into fullscreen, then Ctrl-Cmd-F. **Expect:** it leaves
    fullscreen. **Seen:** ____
11. Cmd-M, then click the window in the Dock. **Expect:** it minimises to
    the Dock, and comes back drawing its text. **Seen:** ____
12. Look at the title, then `:e /tmp/finder-session-2.txt` Return.
    **Expect:** the title is `finder-session.txt`, then
    `finder-session-2.txt`. Then `:q` to close (`:q!` is not offered: save
    or revert first). **Seen:** ____

### Opening from Finder and the Dock (phase 5)

With the installed `/Applications/Leanmacs.app`. Quit it before each step
that starts with it not running.

13. **First, the minos risk** (task `macos-app-minos-platform-version`: the
    executable records `minos 99.0` against `LSMinimumSystemVersion` 27.2).
    In Finder, right-click `/tmp/finder-session.txt` → Open With →
    Leanmacs; quit; then the same with `/tmp/finder-session.c`.
    **Expect:** each time the app starts showing the file: the `.txt`
    exercises the plain-text type, the `.c` the source-code type. If macOS
    refuses ("cannot be opened", "requires a newer version of macOS", or
    nothing happens), record the exact dialog and Console text, add it to
    that task rather than filing a new one, and skip steps 13 to 22; the
    rest can still run. **Seen:** ____
14. With it running, drag `/tmp/finder-session-2.txt` onto the Dock icon.
    **Expect:** that file opens in the window, and the title changes.
    **Seen:** ____
15. Quit. Double-click `/Applications/Leanmacs.app` in Finder. **Expect:**
    it starts on the empty `scratch` buffer. **Seen:** ____
16. Note, two at once: quit; select `/tmp/finder-session.txt` and
    `/tmp/finder-session-2.txt` in Finder, Open With → Leanmacs; then
    `:e /tmp/finder-session.txt`. **Expect:** both open, the second in
    Finder's order is shown, and the first is a buffer too. Record which
    was shown. **Seen:** ____
17. Note, from a terminal: quit; run
    `/Applications/Leanmacs.app/Contents/MacOS/editor /tmp/finder-session.txt`.
    **Expect:** one window with one buffer of that file, not the file
    opened twice (`NSTreatUnknownArgumentsAsOpen = NO`,
    `crates/editor-platform-winit/src/delegate.rs`). `:q`. **Seen:** ____
18. Note, `.lean` files: right-click a `.lean` file → Open With.
    **Expect:** Leanmacs is **not** offered (task `lean-source-uti`).
    Record whether it was; it is not a failure of this phase. **Seen:** ____

### The Finder session (the roadmap's signal)

On the bundle installed by step 0, with config from `~/.config/leanmacs`.

19. Quit. Open `/tmp/finder-session.txt` from Finder (Open With →
    Leanmacs). Then, with it running, open `/tmp/finder-session.c` the same
    way. **Expect:** each is shown in the window. Then
    `:e /tmp/finder-session.txt`. **Seen:** ____
20. Evil edit, then save: `gg`, `dw`, `i`, type `edited `, Escape, `:w`
    Return. Then, in a terminal, `cat /tmp/finder-session.txt`.
    **Expect:** the echo area says `wrote /tmp/finder-session.txt` (or the
    path as resolved), and the file shows the edit. **Seen:** ____
21. The config command: `:finder-hello` Return; then, separately,
    Control-c then `h`. **Expect:** the echo area shows
    `finder-session: config loaded` each time, so config from
    `~/.config/leanmacs` (or `$XDG_CONFIG_HOME/leanmacs`) loaded.
    **Seen:** ____
22. Ctrl-Cmd-F, then again. **Expect:** it enters fullscreen, then leaves
    it. **Seen:** ____

### Docs

23. Read the README's "Installing the macOS app". **Expect:** its commands
    are the ones step 0 used, and it says config is read from
    `~/.config/leanmacs`. **Seen:** ____

## Restore

Quit Leanmacs. Then, with `<ts>` the timestamp step 0 printed (the script
prints these commands with the real paths):

- App: `mv /Applications/Leanmacs.app /Applications/Leanmacs.app.finder-session-<ts>`
  and, if a backup was made,
  `mv /Applications/Leanmacs.app.backup-<ts> /Applications/Leanmacs.app`.
- Config: `mv ~/.config/leanmacs ~/.config/leanmacs.finder-session-<ts>`
  and, if a backup was made,
  `mv ~/.config/leanmacs.backup-<ts> ~/.config/leanmacs` (with
  `$XDG_CONFIG_HOME` in place of `~/.config` if it is set).

Nothing is deleted by these steps; remove the set-aside copies by hand when
satisfied.

## What a failure means

File a task naming the phase it regressed from, for example "regressed
from rdm:phase/macos-app/phase-4-window-requests", or reopen that phase:

- steps 1 to 7: `phase-3-winit-0-31-upgrade` (the green button: display
  pipeline phase 5);
- steps 8 to 12: `phase-4-window-requests`;
- steps 13 to 17 and 19: `phase-5-finder-open`, or `phase-2-app-bundle`
  for a refused launch;
- step 20: command loop phase 9;
- step 21: `phase-1-module-lookup` or `phase-2-app-bundle`.

Once the fix lands, run only the failing step again. The only fixes made
inside phase 6 are to this list, the config fixture
(`tests/headless/finder-session/config`) or the README.
