#!/usr/bin/env bash
#
# read-buffer.sh — re-read the compilation/comint buffer of a finished (or
# running) run-and-read.sh / build-check.sh run, with fresh OUTPUT_GREP /
# OUTPUT_TAIL filters. Never re-runs anything. See ../SKILL.md.
#
# Usage:
#   read-buffer.sh <project-root> [buffer-name]
#   (buffer-name defaults to the compilation buffer found under project-root)
#
# Exit codes: 0 ok, 1 bad args/unknown buffer, 2 emacsclient unreachable,
#   4 no compilation buffer found, 8 Emacs stopped responding

set -u -o pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if [ "$#" -lt 1 ]; then
  echo "Usage: read-buffer.sh <project-root> [buffer-name]" >&2
  exit 1
fi

PROJECT_ROOT=$(abspath "$1") || { echo "ERROR: no such project-root: $1" >&2; exit 1; }
COMP_BUFFER=${2:-}

ping_emacs || exit $?

if [ -z "$COMP_BUFFER" ]; then
  COMP_BUFFER=$(find_comp_buffer "$PROJECT_ROOT")
  [ -n "$COMP_BUFFER" ] || { echo "ERROR: no compilation buffer found under $PROJECT_ROOT" >&2; exit 4; }
fi
echo "==> reading buffer: $COMP_BUFFER" >&2

exists=$(eeval "(and (get-buffer \"$(elquote "$COMP_BUFFER")\") t)")
[ "$exists" = "t" ] || { echo "ERROR: no such buffer: $COMP_BUFFER" >&2; exit 1; }

OUTPUT_FILE=$(mktemp)
dump_buffer "$COMP_BUFFER" "$OUTPUT_FILE" || { rc=$?; rm -f "$OUTPUT_FILE"; exit "$rc"; }
cat "$OUTPUT_FILE"
rm -f "$OUTPUT_FILE"
