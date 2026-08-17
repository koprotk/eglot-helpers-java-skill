#!/usr/bin/env bash
#
# debug-eval.sh — start a dape/JDTLS debug session on a test method, set a
# breakpoint, wait for it to hit, evaluate a Java expression in that paused
# frame (e.g. `driver.getPageSource()` to read a live page's real HTML
# instead of asking the user to open devtools), then resume and tear the
# session down. See ../SKILL.md for the full write-up.
#
# Usage:
#   debug-eval.sh <project-root> <test-file> <fqmn> <bp-file> <bp-line> <expression> \
#                 [hit-timeout=180] [cold-start-timeout=300]
#
# Exit codes (about ORCHESTRATION, not what the expression evaluates to —
# an expression that throws inside the debuggee still exits 0; the error
# text is real signal, not a script failure):
#   0  finished — stdout is the evaluate result (or the debuggee's error)
#   1  usage error
#   2  emacsclient unreachable
#   3  timed out waiting for JDTLS to attach (cold start)
#   4  starting the debug session failed (e.g. debug plugin not loaded --
#      this script does not attempt the interactive Maven-debug fallback)
#   5  timed out waiting for the breakpoint to be hit
#   6  timed out waiting for the evaluate result to appear

set -u -o pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: debug-eval.sh <project-root> <test-file> <fqmn> <bp-file> <bp-line> <expression> [hit-timeout=180] [cold-start-timeout=300]

  project-root   absolute path to the Maven project root (has pom.xml/mvnw)
  test-file      absolute path to the .java file declaring the test method
  fqmn           pkg.Class#method to debug
  bp-file        absolute path to the .java file to set the breakpoint in
                 (often the same as test-file, but can be a Screen class etc.)
  bp-line        1-based line number for the breakpoint
  expression     Java expression to evaluate once the breakpoint hits,
                 e.g. "driver.getPageSource()" or "driver.getCurrentUrl()"

After evaluating, the session is resumed and then torn down (dape-continue
then dape-quit) -- this grabs one snapshot of state and cleans up, it does
not wait for the test to finish or report its outcome. Use run-and-read.sh
for that.
EOF
}

if [ "$#" -lt 6 ]; then
  usage
  exit 1
fi

PROJECT_ROOT_RAW=$1
TEST_FILE_RAW=$2
FQMN=$3
BP_FILE_RAW=$4
BP_LINE=$5
EXPRESSION=$6
HIT_TIMEOUT=${7:-180}
COLD_TIMEOUT=${8:-300}

PROJECT_ROOT=$(abspath "$PROJECT_ROOT_RAW") || { echo "ERROR: no such project-root: $PROJECT_ROOT_RAW" >&2; exit 1; }
TARGET_FILE=$(abspath "$TEST_FILE_RAW") || { echo "ERROR: no such test-file: $TEST_FILE_RAW" >&2; exit 1; }
BP_FILE=$(abspath "$BP_FILE_RAW") || { echo "ERROR: no such bp-file: $BP_FILE_RAW" >&2; exit 1; }

echo "==> checking Emacs server..." >&2
ping_emacs || exit 2

find_or_open_buffer || exit $?

# ---------------------------------------------------------------------------
# Set the breakpoint. dape--breakpoint-place removes any existing breakpoint
# at the line before placing a fresh one, so this is safe to call blind --
# it will not accidentally toggle an existing one off.
# ---------------------------------------------------------------------------
echo "==> setting breakpoint at $BP_FILE:$BP_LINE..." >&2
bp_form=$(render_form '
(progn
  (require (quote dape) nil t)
  (with-current-buffer (find-file-noselect "@@BPFILE@@")
    (goto-char (point-min))
    (forward-line (1- @@BPLINE@@))
    (dape--breakpoint-place)
    t))
' '@@BPFILE@@' "$BP_FILE")
bp_form=${bp_form//@@BPLINE@@/$BP_LINE}
bp_result=$(eeval "$bp_form")
if [ "$bp_result" != "t" ]; then
  echo "ERROR: failed to set breakpoint at $BP_FILE:$BP_LINE" >&2
  exit 4
fi

# ---------------------------------------------------------------------------
# Start the debug session via the same non-interactive helper
# eglot-helpers-java-debug-test-method uses for the LSP/dape fast path.
# This script does not replicate the interactive Maven-debug fallback --
# if the JDTLS debug plugin is not loaded, this fails clearly instead.
# ---------------------------------------------------------------------------
echo "==> starting debug session for ${FQMN}..." >&2
start_form=$(render_form '
(with-current-buffer (get-file-buffer "@@FILE@@")
  (condition-case err
      (progn
        (dape (eglot-helpers-java--debug-launch-config "@@FQMN@@"))
        "t")
    (error (format "ERROR: %s" (error-message-string err)))))
' '@@FILE@@' "$BUFFER_FILE" '@@FQMN@@' "$FQMN")
start_result=$(unquote "$(eeval "$start_form")")
if [ "$start_result" != "t" ]; then
  echo "ERROR: failed to start debug session: $start_result" >&2
  echo "       (this script does not fall back to Maven surefire debug --" >&2
  echo "        try M-x eglot-helpers-java-reload-bundles interactively first)" >&2
  exit 4
fi

# ---------------------------------------------------------------------------
# Poll for the breakpoint to actually be hit.
# ---------------------------------------------------------------------------
echo "==> waiting for the breakpoint to hit (timeout ${HIT_TIMEOUT}s; this runs" >&2
echo "    a real test through to that point, browser automation included)..." >&2
stopped_form='(progn (require (quote dape) nil t) (if (dape--live-connection (quote stopped) t) t nil))'
elapsed=0
while :; do
  stopped=$(eeval "$stopped_form")
  [ "$stopped" = "t" ] && break
  if [ "$elapsed" -ge "$HIT_TIMEOUT" ]; then
    echo "ERROR: hit-timeout (${HIT_TIMEOUT}s) exceeded waiting for the breakpoint to be hit" >&2
    exit 5
  fi
  sleep 2
  elapsed=$((elapsed + 2))
done
echo "==> breakpoint hit." >&2

# ---------------------------------------------------------------------------
# Evaluate the expression, capturing only the *new* tail of *dape-repl*
# (recorded position before the call) so we do not pick up unrelated
# earlier REPL history.
# ---------------------------------------------------------------------------
echo "==> evaluating: ${EXPRESSION}" >&2
before_form='
(progn
  (require (quote dape) nil t)
  (if (get-buffer "*dape-repl*")
      (with-current-buffer "*dape-repl*" (point-max))
    0))
'
before_pos=$(eeval "$before_form")

eval_form=$(render_form '
(progn
  (require (quote dape) nil t)
  (let ((conn (dape--live-connection (quote stopped) t)))
    (if conn
        (progn (dape-evaluate-expression conn "@@EXPR@@" "repl") "t")
      "ERROR: no stopped connection")))
' '@@EXPR@@' "$EXPRESSION")
eval_trigger=$(unquote "$(eeval "$eval_form")")
if [ "$eval_trigger" != "t" ]; then
  echo "ERROR: $eval_trigger" >&2
  exit 6
fi

echo "==> waiting for the result to appear in *dape-repl*..." >&2
elapsed=0
RESULT_FILE=$(mktemp)
got_result=0
while [ "$elapsed" -lt 15 ]; do
  grow_form=$(render_form '
(with-current-buffer "*dape-repl*"
  (if (> (point-max) @@BEFORE@@) t nil))
' '@@BEFORE@@' "$before_pos")
  grow_form=${grow_form//@@BEFORE@@/$before_pos}
  grew=$(eeval "$grow_form")
  if [ "$grew" = "t" ]; then
    dump_form=$(render_form '
(with-current-buffer "*dape-repl*"
  (write-region @@BEFORE@@ (point-max) "@@OUT@@" nil (quote silent)))
' '@@OUT@@' "$RESULT_FILE")
    dump_form=${dump_form//@@BEFORE@@/$before_pos}
    eeval "$dump_form" >/dev/null
    got_result=1
    break
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

if [ "$got_result" -ne 1 ]; then
  echo "ERROR: timed out after 15s waiting for an evaluate result in *dape-repl*" >&2
  rm -f "$RESULT_FILE"
  exit 6
fi

# ---------------------------------------------------------------------------
# Resume, then tear the whole session down. This does not wait for the test
# to actually finish -- it grabs one snapshot and cleans up eagerly so the
# browser/JVM are not left running.
# ---------------------------------------------------------------------------
echo "==> resuming and tearing down the debug session..." >&2
eeval '
(progn
  (require (quote dape) nil t)
  (when-let ((conn (dape--live-connection (quote stopped) t)))
    (dape-continue conn)))
' >/dev/null
sleep 1
eeval '(progn (require (quote dape) nil t) (dape-quit))' >/dev/null

cat "$RESULT_FILE"
rm -f "$RESULT_FILE"
