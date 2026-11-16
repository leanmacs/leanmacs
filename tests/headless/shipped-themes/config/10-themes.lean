-- A config that names a shipped theme, `solarized-light`, which compiled
-- code registers before any config (`Themes.shipped`), so the name is found
-- when the config is installed.
def setup : SetupM Unit :=
  useTheme "solarized-light"
