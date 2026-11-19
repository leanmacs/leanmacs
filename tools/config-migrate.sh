#!/bin/sh
# Converts a config directory from the old form to the form the editor
# loads: `mise run config-migrate [-- <config dir>]`
# (docs/design/lean-runtime.md, "Config and reload").
#
#   tools/config-migrate.sh [<config dir>]
#
# The config directory defaults to `${XDG_CONFIG_HOME:-$HOME/.config}/leanmacs`,
# the one the editor's window mode loads.
#
# The old form is `.lean` files directly in the directory, with no header,
# elaborated in the byte order of their names, each seeing what the ones
# before it defined, with `Editor` imported and opened for them. The form
# the editor loads is a root, `init.lean`, and the config files it imports,
# each a Lean module under `Config/` that writes its own header.
#
# What it does, to the `.lean` files directly in the directory, in the byte
# order of their names:
#
# - each file but the last is moved to `Config/<Name>.lean`, `<Name>` being
#   its name without its leading digits and separators, in upper camel case
#   (`05-leader.lean` gives `Config/Leader.lean`, the module
#   `Config.Leader`);
# - the last is moved to `init.lean`;
# - each gets a header before its text: `import Editor`, an import of the
#   file before it, and `open Editor`. An import brings what the imported
#   file imports, so each file still sees every file before it.
#
# It prints each move. It moves files of the directory and changes nothing
# else: no other file is read, written or removed.
#
# Its limit: the editor runs the `setup` that `init.lean` itself defines,
# and no other. So a config whose `setup` is defined in its last file loads
# once converted. A config whose `setup` is defined in an earlier file is
# converted too, and the editor then refuses it, saying that the root
# defines no `setup`, until that definition is moved to `init.lean`.
#
# It refuses, and changes nothing, exit status 1: a directory that is not
# there; one that already holds an `init.lean`; a file whose name gives no
# module name (after its digits it must be letters, digits, `-` and `_`,
# starting with a letter); two files that give one name; and a
# `Config/<Name>.lean` that is already there. A directory with no `.lean`
# file directly in it has nothing to convert: it says so, exit status 0.
# A command line it does not take is the usage, exit status 2.
set -eu

usage() {
  echo "usage: tools/config-migrate.sh [<config dir>]" >&2
  echo "  converts a config of .lean files in byte order, with no header, to init.lean and Config/<Name>.lean" >&2
  echo "  the config dir defaults to \${XDG_CONFIG_HOME:-\$HOME/.config}/leanmacs" >&2
  echo "  the converted config loads when its setup was defined in its last file: the editor runs the setup init.lean defines" >&2
  exit 2
}

[ "$#" -le 1 ] || usage
case "${1:-}" in
  -*) usage ;;
esac

if [ "$#" -eq 1 ]; then
  dir=$1
else
  dir=${XDG_CONFIG_HOME:-$HOME/.config}/leanmacs
fi

refuse() {
  echo "config-migrate: $1" >&2
  exit 1
}

[ -d "$dir" ] || refuse "there is no directory $dir"
[ ! -e "$dir/init.lean" ] || refuse "$dir already holds an init.lean: it is not a config in the old form"

# The `.lean` files directly in the directory, in the byte order of their
# names, one a line. A name with a newline in it is not a config file's.
files=$(cd "$dir" && for file in *.lean; do
  [ -f "$file" ] && printf '%s\n' "$file"
done | LC_ALL=C sort)

if [ -z "$files" ]; then
  echo "config-migrate: $dir holds no .lean file directly in it: there is nothing to convert"
  exit 0
fi

# The module name a file's name gives: without `.lean` and its leading
# digits and separators, each part after a `-` or `_` capitalised.
module_of() {
  printf '%s\n' "$1" | sed -e 's/\.lean$//' -e 's/^[0-9_-]*//' |
    awk '{
      count = split($0, parts, /[-_]/)
      name = ""
      for (index_ = 1; index_ <= count; index_++)
        name = name toupper(substr(parts[index_], 1, 1)) substr(parts[index_], 2)
      print name
    }'
}

total=$(printf '%s\n' "$files" | wc -l | tr -d ' ')

# Everything is checked before anything is moved.
names=
count=0
while IFS= read -r file; do
  count=$((count + 1))
  [ "$count" -lt "$total" ] || break
  name=$(module_of "$file")
  case "$name" in
    [A-Za-z]*) ;;
    *) refuse "$file gives no module name: after its leading digits its name must start with a letter" ;;
  esac
  case "$name" in
    *[!A-Za-z0-9]*) refuse "$file gives no module name: its name must be letters, digits, - and _" ;;
  esac
  case " $names " in
    *" $name "*) refuse "two files give the module name Config.$name: rename one of them" ;;
  esac
  [ ! -e "$dir/Config/$name.lean" ] || refuse "$dir/Config/$name.lean is already there"
  names="$names $name"
done <<LIST
$files
LIST

# A file's new text: the header, with an import of the file before it when
# there is one, and then its old text.
headed() {
  echo "import Editor"
  [ -z "$2" ] || echo "import Config.$2"
  echo "open Editor"
  echo
  cat "$1"
}

previous=
count=0
while IFS= read -r file; do
  count=$((count + 1))
  if [ "$count" -lt "$total" ]; then
    name=$(module_of "$file")
    mkdir -p "$dir/Config"
    headed "$dir/$file" "$previous" >"$dir/Config/$name.lean"
    rm "$dir/$file"
    echo "config-migrate: moved $file to Config/$name.lean"
    previous=$name
  else
    headed "$dir/$file" "$previous" >"$dir/init.lean.new"
    rm "$dir/$file"
    mv "$dir/init.lean.new" "$dir/init.lean"
    echo "config-migrate: moved $file to init.lean"
  fi
done <<LIST
$files
LIST

echo "config-migrate: converted $dir; the editor runs the setup that init.lean defines, so if yours was defined in another file, move it to init.lean"
