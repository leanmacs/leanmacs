# Text rendering choices

On macOS, text rendering follows what Core Text and native apps (and Ghostty
and Zed) do: glyph placement, quantisation, smoothing and blending. The
design is in `docs/design/text-and-display.md`. Deviate only when the owner
asks for it.

- When matching the platform conflicts with an existing reference picture,
  constant or early renderer choice, match the platform and regenerate,
  without escalating it as an owner decision.
- Treat reference pictures (`tests/render/frame.png`, the theme and excerpt
  pictures) as disposable: regenerate them whenever behaviour changes,
  rather than protecting them with a roadmap non-goal.
