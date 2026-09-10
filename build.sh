#!/bin/bash
# Assemble the self-contained User Scripts from src/.
#
#   ./build.sh
#
# Each src/*.sh carries its own header and CONFIGURATION block and
# pulls in the shared logic with a "#@include common.sh" line. The
# output is a single file with everything inlined, so it can be
# pasted straight into the Unraid User Scripts editor.
#
# Edit src/, never the generated scripts at the repo root.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

build() {
    local src="$1" out="$2"
    awk '
        /^#@include / {
            f = "src/" $2
            while ((getline line < f) > 0) print line
            close(f)
            next
        }
        { print }
    ' "$src" > "$out.tmp"
    mv -- "$out.tmp" "$out"
    chmod +x "$out"
    printf '%-24s <- %s\n' "$out" "$src"
}

build src/film.sh "Library Cleaner Film"
build src/tv.sh   "Library Cleaner TV"
