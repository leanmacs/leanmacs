-- A config in the form the editor no longer loads, kept in that form on
-- purpose (tests/config-migrate/script): a file with no header, elaborated
-- before the one after it in the byte order of the file names. The editor
-- refuses this directory, and `tools/config-migrate.sh` converts a copy of
-- it.

/-- What `greet` says once the directory is converted. -/
def greet : EditorM Unit :=
  message "converted"

/-- What the second file's `setup` calls. -/
def leaderMap : SetupM Unit :=
  command "greet" greet
