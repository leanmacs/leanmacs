Leanmacs

A text editor whose config and extensions are written in Lean.
Source, issues and licence: https://github.com/leanmacs/leanmacs

This is the nightly: an unreleased build made from `main`. To see which
build you have, run

    /Applications/Leanmacs.app/Contents/MacOS/editor --version

It prints the version, the build ID (the commit's time, UTC,
YYYYMMDDHHMMSS) and the commit.

Install:

Drag Leanmacs.app onto Applications in this window.

First launch:

The app is ad-hoc signed and not notarized, so macOS blocks it the first
time. Since macOS 15, Control-click > Open no longer gets past this.
Instead:

1. Open Leanmacs once. macOS says it cannot check it; click Done.
2. Open System Settings > Privacy & Security, scroll down, and click
   "Open Anyway" beside the message about Leanmacs.
3. Open Leanmacs again and confirm.

If that does not work, remove the quarantine flag in Terminal:

    xattr -dr com.apple.quarantine /Applications/Leanmacs.app

Requirements:

macOS 26.0 or later, on Apple silicon.

Config:

Your config lives in ~/.config/leanmacs.

Licence:

GPL-3.0-or-later. The full text is in LICENSE, beside this file.
