#!/usr/bin/env bash
#
# run-and-read.sh — drive eglot-helpers-java's LSP test runner through a
# running Emacs (via emacsclient) and print the resulting compilation
# output. See ../SKILL.md for the full write-up.
#
# Usage:
#   run-and-read.sh <project-root> <target-java-file> <fqn> <class|method> \
#                    [run-timeout-seconds=300] [cold-start-timeout-seconds=300]
#
# Exit codes (about ORCHESTRATION, not test pass/fail — a finished
# compilation buffer with failing tests still exits 0; the failure is in
# the printed text):
#   0  finished — stdout is the full compilation buffer text
#   1  usage error
#   2  emacsclient unreachable
#   3  timed out waiting for JDTLS to attach (cold start)
#   4  no compilation buffer appeared after triggering the run
#   5  run-timeout exceeded waiting for the compilation to finish

set -u -o pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: run-and-read.sh <project-root> <target-java-file> <fqn> <class|method> [run-timeout=300] [cold-start-timeout=300]

  project-root        absolute path to the Maven project root (has pom.xml/mvnw)
  target-java-file    absolute path to the .java file containing the class/method
  fqn                 pkg.Class            (for "class")
                       pkg.Class#method     (for "method")
  class|method        selects JDTLS test level (3=class, 4=method)
EOF
}

if [ "$#" -lt 4 ]; then
  usage
  exit 1
fi

PROJECT_ROOT_RAW=$1
TARGET_FILE_RAW=$2
FQN=$3
KIND=$4
RUN_TIMEOUT=${5:-300}
COLD_TIMEOUT=${6:-300}

case "$KIND" in
  class)  LEVEL=3 ;;
  method) LEVEL=4 ;;
  *)
    echo "ERROR: fourth argument must be 'class' or 'method', got '${KIND}'" >&2
    usage
    exit 1
    ;;
esac

PROJECT_ROOT=$(abspath "$PROJECT_ROOT_RAW") || { echo "ERROR: no such project-root: $PROJECT_ROOT_RAW" >&2; exit 1; }
TARGET_FILE=$(abspath "$TARGET_FILE_RAW") || { echo "ERROR: no such target-java-file: $TARGET_FILE_RAW" >&2; exit 1; }

echo "==> checking Emacs server..." >&2
ping_emacs || exit 2

find_or_open_buffer || exit $?

# ---------------------------------------------------------------------------
# Trigger the run.
# ---------------------------------------------------------------------------
echo "==> running ${KIND} ${FQN}..." >&2
run_form=$(render_form '
(with-current-buffer (get-file-buffer "@@FILE@@")
  (eglot-helpers-java--run-test "@@FQN@@" @@LEVEL@@))
' '@@FILE@@' "$BUFFER_FILE" '@@FQN@@' "$FQN")
run_form=${run_form//@@LEVEL@@/$LEVEL}
eeval "$run_form" >/dev/null

# ---------------------------------------------------------------------------
# Discover the compilation buffer `compile' just created for this project.
# ---------------------------------------------------------------------------
echo "==> locating the compilation buffer..." >&2
find_comp_form=$(render_form '
(progn
  (require (quote cl-lib))
  (let ((root (file-name-as-directory (expand-file-name "@@ROOT@@"))))
    (or (cl-loop for b in (buffer-list)
                 when (and (buffer-live-p b)
                           (with-current-buffer b
                             ;; compile with COMINT=t (what --run-test uses)
                             ;; produces a comint-mode buffer with
                             ;; compilation-shell-minor-mode layered on top,
                             ;; not a compilation-mode major mode -- check both.
                             (and (or (derived-mode-p (quote compilation-mode))
                                      (bound-and-true-p compilation-shell-minor-mode))
                                  default-directory
                                  (string-prefix-p root (expand-file-name default-directory)))))
                 return (buffer-name b))
        "")))
' '@@ROOT@@' "$PROJECT_ROOT")

elapsed=0
COMP_BUFFER=""
while [ "$elapsed" -lt 10 ]; do
  COMP_BUFFER=$(unquote "$(eeval "$find_comp_form")")
  [ -n "$COMP_BUFFER" ] && break
  sleep 1
  elapsed=$((elapsed + 1))
done

if [ -z "$COMP_BUFFER" ]; then
  echo "ERROR: no compilation buffer appeared under $PROJECT_ROOT within 10s of triggering the run" >&2
  exit 4
fi
echo "==> compilation buffer: $COMP_BUFFER" >&2

# ---------------------------------------------------------------------------
# Poll until compile.el's own finish sentinel line appears.
# ---------------------------------------------------------------------------
poll_form=$(render_form '
(with-current-buffer (get-buffer "@@BUF@@")
  (if (save-excursion
        (goto-char (point-max))
        (re-search-backward
         "^Compilation \\(finished\\|exited abnormally\\|segmentation fault\\)" nil t))
      t
    nil))
' '@@BUF@@' "$COMP_BUFFER")

echo "==> waiting for the run to finish (timeout ${RUN_TIMEOUT}s)..." >&2
elapsed=0
while :; do
  done_p=$(eeval "$poll_form")
  [ "$done_p" = "t" ] && break
  if [ "$elapsed" -ge "$RUN_TIMEOUT" ]; then
    echo "ERROR: run-timeout (${RUN_TIMEOUT}s) exceeded waiting for $COMP_BUFFER to finish" >&2
    exit 5
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

# ---------------------------------------------------------------------------
# Print the full buffer via a temp file — sidesteps any Lisp string-escaping
# round-trip through emacsclient's prin1'd return value.
# ---------------------------------------------------------------------------
OUTPUT_FILE=$(mktemp)
dump_form=$(render_form '
(with-current-buffer (get-buffer "@@BUF@@")
  (write-region (point-min) (point-max) "@@OUT@@" nil (quote silent)))
' '@@BUF@@' "$COMP_BUFFER" '@@OUT@@' "$OUTPUT_FILE")
eeval "$dump_form" >/dev/null

cat "$OUTPUT_FILE"
rm -f "$OUTPUT_FILE"
