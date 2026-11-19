-- A config that names a shipped theme, `solarized-light`, which this
-- package registers before any config (`ShippedThemes.package`), so the
-- name is found when the config is installed. It names the theme by its
-- name alone and imports no module of the package.
def setup : SetupM Unit :=
  useTheme "solarized-light"
