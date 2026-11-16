#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/odin-library-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
has_shared=false
for flag do
    case "$flag" in -collection:shared=*) has_shared=true ;; esac
done
if [ "$has_shared" = false ]; then
    set -- "-collection:shared=$(dirname -- "$root")" "$@"
fi
"${ODIN:-odin}" test "$root/tests" -out:"$work/tests" "$@"
