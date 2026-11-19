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
# - The files are cut in two at the first file that must stay with the ones
#   after it, the root's first file: the first file that defines `setup`
#   or declares something `private`. With `setup` defined in the last file
#   and nothing private before it, as most configs are, that is the last
#   file.
# - Each file before it is moved to `Config/<Name>.lean`, `<Name>` being
#   its name without its leading digits and separators, in upper camel case
#   (`05-leader.lean` gives `Config/Leader.lean`, the module
#   `Config.Leader`). It gets a header before its text: `import Editor`, an
#   import of the file before it, and `open Editor`. An import brings what
#   the imported file imports, so each file still sees every file before
#   it.
# - The root's first file and every file after it become `init.lean`, in
#   order, under one header that imports the last file moved to `Config/`.
#   When they are several, each but the last is put in a `section` of its
#   own, so what it opens ends where it ended in the old form, at the end
#   of the file.
#
# Why the cut. The editor runs the `setup` that `init.lean` itself defines,
# and the old form ran the `setup` of whichever file defined it; a
# declaration named `setup` in an imported module could not be defined
# again in the root. So the file that defines `setup` goes in the root,
# with the files after it, which may name what it declares. And a
# `private` declaration is visible in its own module alone, while the old
# form's files were one module, so a file that declares one stays with the
# files after it too. A config so converted loads as the old one did.
#
# How it tells. From the text, a line at a time, with no Lean: a file
# defines `setup` when a line of it starts a declaration of that name
# (`def setup`, `abbrev setup`, after any modifiers and attributes on the
# line), and declares something private when a line starts with `private`.
# When no file has such a line for `setup`, it cannot tell where `setup`
# is, and every file becomes part of `init.lean`: that always loads.
#
# It prints what it did. It moves files of the directory and changes
# nothing else: no other file is read, written or removed.
#
# It refuses, and changes nothing, exit status 1:
#
# - a directory that is not there, and one that already holds an
#   `init.lean`;
# - a file that would move to `Config/` whose name gives no module name
#   (after its digits it must be letters, digits, `-` and `_`, starting
#   with a letter), two such files that give one name, and a
#   `Config/<Name>.lean` that is already there;
# - a file that would go in `init.lean` before another and leaves a
#   namespace, a section or a `mutual` block open at its end, which it
#   names. In the old form what a file left open ended with the file; in
#   one file it would swallow the files after it, and no line this script
#   could add closes a namespace it cannot name. It counts the lines that
#   start with `namespace`, `section` or `mutual` against the lines that
#   start with `end`. Close it in the file, or move the definition of
#   `setup` to the last file, and run the script again.
#
# A directory with no `.lean` file directly in it has nothing to convert:
# it says so, exit status 0. A command line it does not take is the usage,
# exit status 2.
set -eu

usage() {
  echo "usage: tools/config-migrate.sh [<config dir>]" >&2
  echo "  converts a config of .lean files in byte order, with no header, to init.lean and Config/<Name>.lean" >&2
  echo "  the config dir defaults to \${XDG_CONFIG_HOME:-\$HOME/.config}/leanmacs" >&2
  echo "  the file that defines setup, and the files after it, become init.lean; the files before it become Config/<Name>.lean" >&2
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

# Whether a line of the file `$1` starts a declaration of `setup`, after
# any attributes and modifiers on the line.
defines_setup() {
  grep -Eq '^(@\[[^]]*\][[:space:]]*)*((private|protected|noncomputable|partial|unsafe|nonrec)[[:space:]]+)*(def|abbrev|opaque|instance|theorem|axiom)[[:space:]]+setup([^A-Za-z0-9_.!?'"'"']|$)' "$1"
}

# Whether a line of the file `$1` starts with `private`, after any
# attributes on the line.
declares_private() {
  grep -Eq '^(@\[[^]]*\][[:space:]]*)*private[[:space:]]' "$1"
}

# How many more lines of the file `$1` start with `namespace`, `section` or
# `mutual` than start with `end`: 0 when it leaves nothing open.
left_open() {
  awk '
    /^(noncomputable[ \t]+|public[ \t]+|private[ \t]+)?(namespace|section|mutual)([^A-Za-z0-9_]|$)/ { depth++ }
    /^end([^A-Za-z0-9_]|$)/ { depth-- }
    END { print depth + 0 }
  ' "$1"
}

# The root's first file: the place, from 1, of the first file that defines
# `setup` or declares something private. When no file is seen to define
# `setup`, the first file: every file then goes in `init.lean`.
first=
seen_setup=no
count=0
while IFS= read -r file; do
  count=$((count + 1))
  if defines_setup "$dir/$file"; then
    seen_setup=yes
    [ -n "$first" ] || first=$count
  elif declares_private "$dir/$file"; then
    [ -n "$first" ] || first=$count
  fi
done <<LIST
$files
LIST
[ "$seen_setup" = yes ] || first=1

# Everything is checked before anything is moved.
names=
count=0
while IFS= read -r file; do
  count=$((count + 1))
  if [ "$count" -lt "$first" ]; then
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
  elif [ "$count" -lt "$total" ]; then
    [ "$(left_open "$dir/$file")" -eq 0 ] ||
      refuse "$file leaves a namespace, a section or a mutual block open at its end (or closes one it did not open), and it would go in init.lean before the files after it, which that would change: close it in the file, or move the definition of setup to the last file, and run this again"
  fi
done <<LIST
$files
LIST

# The header of a converted file: with an import of the file before it when
# there is one.
header() {
  echo "import Editor"
  [ -z "$1" ] || echo "import Config.$1"
  echo "open Editor"
  echo
}

previous=
merged=
count=0
: >"$dir/init.lean.new"
while IFS= read -r file; do
  count=$((count + 1))
  if [ "$count" -lt "$first" ]; then
    name=$(module_of "$file")
    mkdir -p "$dir/Config"
    { header "$previous"; cat "$dir/$file"; } >"$dir/Config/$name.lean"
    rm "$dir/$file"
    echo "config-migrate: moved $file to Config/$name.lean"
    previous=$name
  else
    [ "$count" -ne "$first" ] || header "$previous" >>"$dir/init.lean.new"
    if [ "$first" -lt "$total" ]; then
      # Several files in the root: each says where it came from, and each
      # but the last is a section, so what it opens ends with it.
      echo "-- From $file:" >>"$dir/init.lean.new"
      if [ "$count" -lt "$total" ]; then
        { echo "section"; echo; cat "$dir/$file"; echo; echo "end"; echo; } >>"$dir/init.lean.new"
      else
        cat "$dir/$file" >>"$dir/init.lean.new"
      fi
    else
      cat "$dir/$file" >>"$dir/init.lean.new"
    fi
    rm "$dir/$file"
    merged="$merged $file"
  fi
done <<LIST
$files
LIST
mv "$dir/init.lean.new" "$dir/init.lean"

if [ "$first" -lt "$total" ]; then
  if [ "$seen_setup" = yes ]; then
    reason="the first of them defines setup or declares something private, and the editor runs the setup that init.lean itself defines"
  else
    reason="no line of any file was seen to define setup, so they are kept together"
  fi
  echo "config-migrate: put$merged in init.lean, in that order: $reason"
else
  echo "config-migrate: moved$merged to init.lean"
fi
echo "config-migrate: converted $dir"
