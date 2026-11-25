#!/bin/sh
# Reserve the compiler's output directory before the Odin tool can start.
set -eu
package=$1
shift
runner_dir=$(mktemp -d "${TMPDIR:-/tmp}/kakunou-task-XXXXXXXX")
trap 'rm -f "$runner_dir/runner"; rmdir "$runner_dir"' EXIT
trap 'exit 1' HUP INT TERM
"$KAKUNOU_COMPILER" run "$package" -out:"$runner_dir/runner" "$@"
