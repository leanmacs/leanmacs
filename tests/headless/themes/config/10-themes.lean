-- Two themes of this config's own, each a background of its own over the
-- faces `default` leaves to the theme under it, and the first named as the
-- one in force. Until the shipped themes beyond `default` exist, both
-- themes the script switches between are the config's.
def first : Theme :=
  #[{ name := ⟨"default"⟩, face := { background := some (Color.rgb 20 20 60) } }]

def second : Theme :=
  #[{ name := ⟨"default"⟩, face := { background := some (Color.rgb 60 20 20) } }]

def setup : SetupM Unit := do
  defineTheme "first" first
  defineTheme "second" second
  useTheme "first"
