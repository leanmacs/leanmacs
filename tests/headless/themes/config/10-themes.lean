-- Two themes of this config's own, and the first named as the one in force.
-- A theme in force replaces the built-in theme wholesale, so each is the
-- built-in theme followed by a `default` of its own background, which is
-- over the built-in `default`; the rest of the built-in faces stay. Until
-- the shipped themes beyond `default` exist, both themes the script
-- switches between are the config's.
def first : Theme :=
  Theme.builtin ++
    #[{ name := ⟨"default"⟩, face := { background := some (Color.rgb 20 20 60) } }]

def second : Theme :=
  Theme.builtin ++
    #[{ name := ⟨"default"⟩, face := { background := some (Color.rgb 60 20 20) } }]

def setup : SetupM Unit := do
  defineTheme "first" first
  defineTheme "second" second
  useTheme "first"
