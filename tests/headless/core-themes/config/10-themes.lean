-- One theme of this config's own, `first`, and no theme named as the one in
-- force: the built-in theme followed by a `default` of its own background.
-- The script runs on an editor built from the core alone, so the themes it
-- has are the core's `default` and this one.
def first : Theme :=
  Theme.builtin ++
    #[{ name := ⟨"default"⟩, face := { background := some (Color.rgb 20 20 60) } }]

def setup : SetupM Unit :=
  defineTheme "first" first
