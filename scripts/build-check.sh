#!/usr/bin/env bash
#
# build-check.sh — cheap "does it still compile" check via JDTLS's own
# java/buildWorkspace LSP request (same one eglot-helpers-java-build-workspace
# uses interactively), plus the Flymake diagnostics for the target file.
# Much lighter than running a test class — use this right after editing a
# .java file, save run-and-read.sh for actually exercising tests.
#
# Usage:
#   build-check.sh <project-root> <target-java-file> [full=0] \
#                  [request-timeout-seconds] [cold-start-timeout-seconds] \
#                  [mvn-fallback-timeout-seconds]
#   (defaults: DEFAULT_REQUEST_TIMEOUT/DEFAULT_MVN_FALLBACK_TIMEOUT below,
#    DEFAULT_COLD_TIMEOUT in lib.sh -- `usage()` prints the live values,
#    this comment intentionally doesn't repeat the numbers so it can't
#    drift out of sync with them)
#
# Exit codes (about ORCHESTRATION, not compile outcome — a FAILED build
# status still exits 0; that's real signal in the printed text, not a
# script failure):
#   0  finished — stdout has the build status and any Flymake diagnostics
#      (or, if the mvn fallback ran, the full mvn compilation buffer)
#   1  usage error
#   2  emacsclient unreachable
#   3  timed out waiting for JDTLS to attach (cold start)
#   4  no compilation buffer appeared within 10s of triggering the mvn
#      fallback build (only reachable via that path now)
#   5  mvn-fallback-timeout exceeded waiting for the fallback build to finish
#   8  Emacs stopped responding (main thread wedged) before the
#      java/buildWorkspace request returned -- see lib.sh's eeval. Its own
#      :timeout is a *request*, not a guarantee; a connection that dies
#      mid-request can still leave Emacs blocked past it.
#
# Fallback: if this buffer has NO active Eglot server (JDTLS never attached,
# or its connection died), this script does not just exit and tell you --
# it falls back to `eglot-helpers-java-mvn-build-project-skiptests' (`mvnw
# clean package -DskipTests -U'), the same way run-and-read.sh falls back to
# `mvnw -Dtest=... test' when the JDTLS test plugin isn't loaded. Scoped to
# ONLY this condition, not e.g. a cold-start timeout or a wedged Emacs:
# `eglot-helpers-java-mvn-build-project-skiptests' itself warns that `mvnw
# clean' deletes target/classes outside Eclipse's resource API and can
# corrupt the JDTLS workspace cache (ObjectNotFoundException at next
# startup) for any OTHER buffer in the same project that still has a live
# JDTLS session -- triggering it while JDTLS is mid-attach is exactly that
# collision. "No active server on this buffer" is the one case where
# there's nothing live here to corrupt.

set -u -o pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

DEFAULT_REQUEST_TIMEOUT=120
DEFAULT_MVN_FALLBACK_TIMEOUT=900

usage() {
  cat >&2 <<EOF
Usage: build-check.sh <project-root> <target-java-file> [full=0] [request-timeout=$DEFAULT_REQUEST_TIMEOUT] [cold-start-timeout=$DEFAULT_COLD_TIMEOUT] [mvn-fallback-timeout=$DEFAULT_MVN_FALLBACK_TIMEOUT]

  project-root        absolute path to the Maven project root (has pom.xml/mvnw)
  target-java-file    absolute path to the .java file to check
  full                1 to force a full rebuild instead of incremental (default 0)
EOF
}

if [ "$#" -lt 2 ]; then
  usage
  exit 1
fi

PROJECT_ROOT_RAW=$1
TARGET_FILE_RAW=$2
FULL=${3:-0}
REQUEST_TIMEOUT=${4:-$DEFAULT_REQUEST_TIMEOUT}
COLD_TIMEOUT=${5:-$DEFAULT_COLD_TIMEOUT}
MVN_FALLBACK_TIMEOUT=${6:-$DEFAULT_MVN_FALLBACK_TIMEOUT}

PROJECT_ROOT=$(abspath "$PROJECT_ROOT_RAW") || { echo "ERROR: no such project-root: $PROJECT_ROOT_RAW" >&2; exit 1; }
TARGET_FILE=$(abspath "$TARGET_FILE_RAW") || { echo "ERROR: no such target-java-file: $TARGET_FILE_RAW" >&2; exit 1; }

echo "==> checking Emacs server..." >&2
ping_emacs || exit $?

find_or_open_buffer || exit $?

has_server_form=$(render_form '
(with-current-buffer (get-file-buffer "@@FILE@@")
  (and (eglot-current-server) t))
' '@@FILE@@' "$BUFFER_FILE")
has_server=$(eeval "$has_server_form")
has_server_rc=$?
if [ "$has_server_rc" -eq 124 ]; then
  echo "ERROR: Emacs stopped responding on a trivial check right before the build request. Wedged main thread -- check the target Emacs directly." >&2
  exit 8
fi
if [ "$has_server" != "t" ]; then
  echo "==> no active Eglot server on $BUFFER_FILE -- falling back to eglot-helpers-java-mvn-build-project-skiptests (mvnw clean package -DskipTests -U)" >&2
  echo "==> note: this runs 'mvnw clean', which can corrupt the JDTLS workspace cache of any OTHER buffer in this project that still has a live JDTLS session -- this buffer has none, so that's not a risk here." >&2

  trigger_form=$(render_form '
(with-current-buffer (get-file-buffer "@@FILE@@")
  (eglot-helpers-java-mvn-build-project-skiptests))
' '@@FILE@@' "$BUFFER_FILE")
  eeval "$trigger_form" >/dev/null
  if [ $? -eq 124 ]; then
    echo "ERROR: Emacs stopped responding while triggering the mvn fallback build. Wedged main thread -- check the target Emacs directly." >&2
    exit 8
  fi

  echo "==> locating the mvn compilation buffer..." >&2
  find_comp_form=$(render_form '
(progn
  (require (quote cl-lib))
  (let ((root (file-name-as-directory (expand-file-name "@@ROOT@@"))))
    (or (cl-loop for b in (buffer-list)
                 when (and (buffer-live-p b)
                           (with-current-buffer b
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
    echo "ERROR: no compilation buffer appeared under $PROJECT_ROOT within 10s of triggering the mvn fallback build" >&2
    exit 4
  fi
  echo "==> mvn compilation buffer: $COMP_BUFFER" >&2

  SENTINEL_FILE=$(mktemp)
  rm -f "$SENTINEL_FILE"
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

  echo "==> waiting for the mvn fallback build to finish (timeout ${MVN_FALLBACK_TIMEOUT}s)..." >&2
  HEALTH_INTERVAL=10
  elapsed=0
  since_health=0
  while [ ! -f "$SENTINEL_FILE" ]; do
    if [ "$elapsed" -ge "$MVN_FALLBACK_TIMEOUT" ]; then
      echo "ERROR: mvn-fallback-timeout (${MVN_FALLBACK_TIMEOUT}s) exceeded waiting for $COMP_BUFFER to finish" >&2
      rm -f "$SENTINEL_FILE"
      exit 5
    fi
    if [ "$since_health" -ge "$HEALTH_INTERVAL" ]; then
      since_health=0
      ping_emacs >/dev/null 2>&1
      if [ $? -eq 8 ]; then
        echo "ERROR: Emacs stopped responding while waiting for $COMP_BUFFER to finish (no reply within ${EMACSCLIENT_TIMEOUT}s on a trivial check). Not safe to keep waiting on a wedged Emacs -- check it directly." >&2
        rm -f "$SENTINEL_FILE"
        exit 8
      fi
    fi
    sleep 1
    elapsed=$((elapsed + 1))
    since_health=$((since_health + 1))
  done
  rm -f "$SENTINEL_FILE"

  OUTPUT_FILE=$(mktemp)
  dump_form=$(render_form '
(with-current-buffer (get-buffer "@@BUF@@")
  (write-region (point-min) (point-max) "@@OUT@@" nil (quote silent)))
' '@@BUF@@' "$COMP_BUFFER" '@@OUT@@' "$OUTPUT_FILE")
  eeval "$dump_form" >/dev/null

  echo "Build status: ran via mvn fallback -- see build output below for pass/fail"
  echo
  cat "$OUTPUT_FILE"
  rm -f "$OUTPUT_FILE"
  exit 0
fi

STATUS_FILE=$(mktemp)
DIAG_FILE=$(mktemp)
FULL_LISP=":json-false"
[ "$FULL" = "1" ] && FULL_LISP="t"

echo "==> requesting java/buildWorkspace (full=${FULL})..." >&2
build_form=$(render_form '
(progn
  (require (quote jsonrpc))
  (require (quote flymake) nil t)
  (let* ((buf (get-file-buffer "@@FILE@@"))
         (server (with-current-buffer buf (eglot-current-server)))
         ;; Flymake-mode is not guaranteed to be on just because Eglot
         ;; manages the buffer (depends on config) -- force it so the
         ;; diagnostics read below actually has something to report.
         (_ (with-current-buffer buf
              (unless (bound-and-true-p flymake-mode) (flymake-mode 1))))
         (status
          (condition-case err
              (format "%s" (jsonrpc-request
                            server :java/buildWorkspace @@FULL@@
                            :timeout @@REQTIMEOUT@@))
            (error (format "ERROR: %s" (error-message-string err))))))
    (write-region status nil "@@STATUSFILE@@" nil (quote silent))
    ;; Give JDTLS a moment to push textDocument/publishDiagnostics after the
    ;; build response before we read Flymake — they are separate messages.
    (sleep-for 1)
    (let ((diag-text
           (with-current-buffer buf
             (if (bound-and-true-p flymake-mode)
                 (let ((s (mapconcat
                      (lambda (d)
                        (format "%s:%d: %s: %s"
                                (file-name-nondirectory (buffer-file-name buf))
                                (line-number-at-pos (flymake-diagnostic-beg d))
                                (pcase (flymake-diagnostic-type d)
                                  (`eglot-error "error")
                                  (`eglot-warning "warning")
                                  (`eglot-note "note")
                                  (_ "diagnostic"))
                                (flymake-diagnostic-text d)))
                      (flymake-diagnostics) "\n")))
                   (if (string-empty-p s) "(no diagnostics)" s))
               "(flymake-mode not active in this buffer)"))))
      (write-region diag-text nil "@@DIAGFILE@@" nil (quote silent)))))
' '@@FILE@@' "$BUFFER_FILE" '@@STATUSFILE@@' "$STATUS_FILE" '@@DIAGFILE@@' "$DIAG_FILE")
build_form=${build_form//@@FULL@@/$FULL_LISP}
build_form=${build_form//@@REQTIMEOUT@@/$REQUEST_TIMEOUT}
# jsonrpc-request's own :timeout above is a *request*, not a guarantee --
# if the connection dies in a way that doesn't trip it cleanly, the
# synchronous eval (and Emacs's main thread with it) can hang past
# REQUEST_TIMEOUT anyway. Give eeval a ceiling of REQUEST_TIMEOUT plus
# generous margin so we still notice and fail fast instead of hanging
# indefinitely on top of jsonrpc's own wait.
eeval "$build_form" $((REQUEST_TIMEOUT + 30)) >/dev/null
build_rc=$?
if [ "$build_rc" -eq 124 ]; then
  echo "ERROR: Emacs stopped responding during java/buildWorkspace (no reply within $((REQUEST_TIMEOUT + 30))s) -- past jsonrpc's own ${REQUEST_TIMEOUT}s request timeout, so the connection likely died/wedged rather than the build genuinely running long. The Emacs main thread may still be stuck; check it directly (C-g, M-x eglot-reconnect, or restart JDTLS) before retrying." >&2
  rm -f "$STATUS_FILE" "$DIAG_FILE"
  exit 8
fi

status=$(cat "$STATUS_FILE")
rm -f "$STATUS_FILE"

case "$status" in
  0) status_human="FAILED" ;;
  1) status_human="SUCCEEDED" ;;
  2) status_human="WITHDRAWN (superseded by another build)" ;;
  3) status_human="CANCELLED" ;;
  *) status_human="$status" ;;
esac

echo "Build status: ${status_human}"
echo
echo "Diagnostics for $(basename "$TARGET_FILE"):"
cat "$DIAG_FILE"
rm -f "$DIAG_FILE"
