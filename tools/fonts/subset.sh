#!/bin/sh
# Makes the fixture fonts of tests/fonts from the upstream font files.
#
#   tools/fonts/subset.sh <directory of the upstream files> [<output directory>]
#
# Run by hand, once, when the fixture fonts change; never by the gate, which
# needs only the files checked in. tests/fonts/README.md says where each
# upstream file comes from (repository, commit and path) and what the tests
# rest on in each.
#
# The first argument is a directory that holds the five upstream files under
# the names their repositories give them. Each is checked against its pinned
# sha256 before it is read, so a file that is not the pinned one is refused.
# Four are subset to the characters the tests shape, with every layout
# feature and every name record kept (the `fi` ligature and the family names
# the tests rest on) and the missing glyph's outline kept; the Hebrew file
# is small and is copied whole. The output directory is tests/fonts of this
# checkout unless a second argument names another.
#
# The subsetter is fonttools' pyftsubset at an exact version, run through
# `uvx`, which fetches it into uv's own cache: nothing is installed into
# the checkout or the system. `--no-recalc-timestamp` keeps the upstream
# file's modification time in the font, so two runs give the same bytes.

set -eu

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "usage: $0 <directory of the upstream files> [<output directory>]" >&2
    exit 2
fi

src=$1
out=${2:-"$(cd "$(dirname "$0")/../.." && pwd)/tests/fonts"}
mkdir -p "$out"

fonttools="fonttools==4.61.0"

# The sha256 of a file, with whichever of the two tools the system has.
sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d ' ' -f 1
    else
        shasum -a 256 "$1" | cut -d ' ' -f 1
    fi
}

# pinned <upstream file> <sha256>: refuses a file that is not the pinned one.
pinned() {
    actual=$(sha256 "$src/$1")
    if [ "$actual" != "$2" ]; then
        echo "$0: $src/$1 is not the pinned file: its sha256 is $actual, not $2" >&2
        exit 1
    fi
}

# subset <upstream file> <sha256> <output file> <characters>
subset() {
    pinned "$1" "$2"
    uvx --from "$fonttools" pyftsubset "$src/$1" \
        --output-file="$out/$3" \
        --unicodes="$4" \
        --layout-features='*' \
        --name-IDs='*' \
        --name-languages='*' \
        --notdef-outline \
        --no-recalc-timestamp
}

# whole <upstream file> <sha256>
whole() {
    pinned "$1" "$2"
    cp "$src/$1" "$out/$1"
}

# The primary: proportional, with the `fi` ligature. Printable ASCII, Latin-1,
# the combining acute accent, the euro sign and the replacement character.
subset NotoSans-Regular.ttf \
    478c558ea716033cd60c03438f628dfa75694dcf6b5f6d505a2f05fd2b4f3823 \
    NotoSans-Regular.subset.ttf \
    'U+0020-007E,U+00A0-00FF,U+0301,U+20AC,U+FFFD'

# The monospace font: printable ASCII.
subset NotoSansMono-Regular.ttf \
    65b5e2b2c4a1fba9ae8be1f026cb35b03dcb8886d9b2a4147054fde12f7e767d \
    NotoSansMono-Regular.subset.ttf \
    'U+0020-007E'

# Hebrew, whole.
whole NotoSansHebrew-Regular.ttf \
    cdefaf8efd47045f6820928eba84db5bed7557539328952b5f828315485e02ee

# The CJK fallback: the three characters of "日本語".
subset NotoSansJP-Regular.otf \
    dff723ba59d57d136764a04b9b2d03205544f7cd785a711442d6d2d085ac5073 \
    NotoSansJP-Regular.subset.otf \
    'U+65E5,U+672C,U+8A9E'

# The emoji fallback: the grinning face.
subset 'NotoEmoji[wght].ttf' \
    de6c18832938afc99caf132b39d6a30a19bac7f2e812e28db2535b4608d27551 \
    NotoEmoji.subset.ttf \
    'U+1F600'

echo "$0: wrote the fixture fonts to $out"
