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
#                  [request-timeout-seconds=120] [cold-start-timeout-seconds=300]
#
# Exit codes (about ORCHESTRATION, not compile outcome — a FAILED build
# status still exits 0; that's real signal in the printed text, not a
# script failure):
#   0  finished — stdout has the build status and any Flymake diagnostics
#   1  usage error
#   2  emacsclient unreachable
#   3  timed out waiting for JDTLS to attach (cold start)
#   4  no active Eglot server on the target buffer after find/open

set -u -o pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: build-check.sh <project-root> <target-java-file> [full=0] [request-timeout=120] [cold-start-timeout=300]

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
REQUEST_TIMEOUT=${4:-120}
COLD_TIMEOUT=${5:-300}

PROJECT_ROOT=$(abspath "$PROJECT_ROOT_RAW") || { echo "ERROR: no such project-root: $PROJECT_ROOT_RAW" >&2; exit 1; }
TARGET_FILE=$(abspath "$TARGET_FILE_RAW") || { echo "ERROR: no such target-java-file: $TARGET_FILE_RAW" >&2; exit 1; }

echo "==> checking Emacs server..." >&2
ping_emacs || exit 2

find_or_open_buffer || exit $?

has_server_form=$(render_form '
(with-current-buffer (get-file-buffer "@@FILE@@")
  (and (eglot-current-server) t))
' '@@FILE@@' "$BUFFER_FILE")
has_server=$(eeval "$has_server_form")
if [ "$has_server" != "t" ]; then
  echo "ERROR: no active Eglot server on $BUFFER_FILE" >&2
  exit 4
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
eeval "$build_form" >/dev/null

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
