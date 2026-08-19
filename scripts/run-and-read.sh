#!/usr/bin/env bash
#
# run-and-read.sh — drive eglot-helpers-java's LSP test runner through a
# running Emacs (via emacsclient) and print the resulting compilation
# output. See ../SKILL.md for the full write-up.
#
# Usage:
#   run-and-read.sh <project-root> <target-java-file> <fqn> <class|method> \
#                    [run-timeout-seconds=700] [cold-start-timeout-seconds=300]
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
#   7  Eglot's connection to JDTLS died mid-run (server process no longer
#      live) -- caught early via a periodic health check instead of
#      silently waiting out the full run-timeout with no signal
#   8  Emacs stopped responding (main thread wedged) mid-run

set -u -o pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: run-and-read.sh <project-root> <target-java-file> <fqn> <class|method> [run-timeout=700] [cold-start-timeout=300]

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
RUN_TIMEOUT=${5:-700}
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
ping_emacs || exit $?

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
# Wait for the run to finish. NOT regex-scraping the buffer for a finish
# line -- compile.el's own exit message is prefixed with `mode-name', not a
# hardcoded "Compilation": a COMINT buffer (what --run-test uses) says
# "Comint exited abnormally...", not "Compilation exited abnormally...", so
# a "^Compilation " pattern silently never matches and this would wait out
# the full timeout on every single run regardless of how fast the test
# actually finished (found live: a real 3m45s run that had already failed
# and exited was still "not detected" under the old regex).
#
# Register a one-shot compilation-finish-functions hook instead -- fires
# exactly once, on the real process-exit event, independent of mode-name or
# message wording -- and have it write a sentinel file bash can just stat.
# Guard the race where the process already finished before we got here
# (fast/trivial runs): write the sentinel ourselves in that case since the
# hook cannot fire retroactively for an already-dead process.
# ---------------------------------------------------------------------------
SENTINEL_FILE=$(mktemp)
rm -f "$SENTINEL_FILE"  # hook (or the race branch) creates it; absence == not done yet
hook_form=$(render_form '
(with-current-buffer (get-buffer "@@BUF@@")
  (if (process-live-p (get-buffer-process (current-buffer)))
      (add-hook (quote compilation-finish-functions)
                (lambda (_buf _msg) (write-region "done" nil "@@SENTINEL@@" nil (quote silent)))
                nil t)
    (write-region "done" nil "@@SENTINEL@@" nil (quote silent)))
  t)
' '@@BUF@@' "$COMP_BUFFER" '@@SENTINEL@@' "$SENTINEL_FILE")
eeval "$hook_form" >/dev/null

echo "==> waiting for the run to finish (timeout ${RUN_TIMEOUT}s)..." >&2
# The sentinel check itself is pure filesystem polling -- no emacsclient
# call, so it cannot hang. But that also means it gives no signal if the
# Eglot/JDTLS connection dies mid-run (this is the case that motivated
# adding it: a lost connection was only discovered after the full
# run-timeout had silently ticked by). Interleave a cheap health check
# every HEALTH_INTERVAL seconds so a dead connection surfaces immediately
# instead of at the very end of the budget.
HEALTH_INTERVAL=10
elapsed=0
since_health=0
while [ ! -f "$SENTINEL_FILE" ]; do
  if [ "$elapsed" -ge "$RUN_TIMEOUT" ]; then
    echo "ERROR: run-timeout (${RUN_TIMEOUT}s) exceeded waiting for $COMP_BUFFER to finish" >&2
    rm -f "$SENTINEL_FILE"
    exit 5
  fi
  if [ "$since_health" -ge "$HEALTH_INTERVAL" ]; then
    since_health=0
    alive=$(eglot_alive "$BUFFER_FILE")
    alive_rc=$?
    if [ "$alive_rc" -eq 124 ]; then
      echo "ERROR: Emacs stopped responding while waiting for $COMP_BUFFER to finish (no reply within ${EMACSCLIENT_TIMEOUT}s on a trivial check). Not safe to keep waiting on a wedged Emacs -- check it directly." >&2
      rm -f "$SENTINEL_FILE"
      exit 8
    fi
    if [ "$alive" != "t" ]; then
      echo "ERROR: Eglot's connection to JDTLS died while waiting for $COMP_BUFFER to finish (server process no longer live). The compilation buffer may be orphaned -- restart the connection (M-x eglot-reconnect or eglot-helpers-java-restart-server-clean) and retry." >&2
      rm -f "$SENTINEL_FILE"
      exit 7
    fi
  fi
  sleep 1
  elapsed=$((elapsed + 1))
  since_health=$((since_health + 1))
done
rm -f "$SENTINEL_FILE"

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
